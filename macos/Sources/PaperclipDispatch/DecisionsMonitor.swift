import AppKit

/// Revisa Decisions de Paperclip cada minuto, pone en el Dock el mismo número que la burbuja de Decisions de
/// la barra lateral (`Attention.deskBadgeCount`) y avisa con un aviso de macOS cuando llega una decisión
/// nueva. Lo hace la app y no la página, porque macOS frena las páginas que no se ven: así sigue avisando
/// con la ventana cerrada (Cmd+W).
///
/// Usa la misma API que la barra lateral de Paperclip (`GET /api/companies/{id}/attention`), con la sesión
/// iniciada en la página. Decisions incluye también los fallos de los agentes y las alertas de presupuesto.
/// Lo que lee se lo pasa también a los canales (`onAttention`), que llevan las decisiones fuera de la Mac.
@MainActor
final class DecisionsMonitor {
    /// La barra lateral de Paperclip pide /attention cada 60 s.
    private static let pollInterval: TimeInterval = 60
    /// La primera vez que la app ve una company avisa de lo que ya estaba pendiente; si es más que esto,
    /// en un solo aviso.
    private static let individualLimit = 3
    /// Lo ya avisado, por company, para no repetir avisos al reabrir la app.
    private static let seenKey = "seenDecisions"
    /// Tope de ids recordados por company (una página de Decisions trae hasta `Attention.pageLimit`).
    private static let seenLimit = 500

    /// Lo pendiente de una company en cada revisión que salió bien. `complete` es falso si no entró todo
    /// en una página: lo que falta no está resuelto.
    var onAttention: ((_ companyId: String, _ items: [AttentionItem], _ complete: Bool) -> Void)?
    /// Cada revisión que salió bien: hay sesión iniciada en Paperclip. Lo usan las sugerencias y el
    /// recordatorio de avisos, que esperan a que se esté usando Paperclip de verdad.
    var onSignedIn: (() -> Void)?
    /// La última revisión no tenía sesión: la página está en la pantalla de inicio.
    private(set) var signedOut = false

    private let api: PaperclipAPI
    private let resolver: DecisionResolver
    private let reviewWaker: ReviewWaker
    private let preferences: Preferences
    private let notifications: NotificationBridge
    private let isLooking: () -> Bool
    private var timer: Timer?
    private var polling = false
    private var pollAgain = false
    private var pendingCount = 0
    /// Las tareas que se están despertando ahora, para no mandar dos veces el mismo despertar.
    private var waking: Set<String> = []

    init(
        api: PaperclipAPI,
        preferences: Preferences,
        notifications: NotificationBridge,
        isLooking: @escaping () -> Bool
    ) {
        self.api = api
        resolver = DecisionResolver(api: api)
        reviewWaker = ReviewWaker(api: api, resolver: resolver)
        self.preferences = preferences
        self.notifications = notifications
        self.isLooking = isLooking
    }

    func start() {
        refresh()
        let timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer.tolerance = Self.pollInterval / 6
        self.timer = timer
    }

    func refresh() {
        Task { await poll() }
    }

    /// Cuando cambia el ajuste del número del Dock.
    func applyBadge() {
        NSApp.dockTile.badgeLabel = preferences.dockBadge && pendingCount > 0 ? String(pendingCount) : nil
    }

    private func poll() async {
        // Si piden revisar a mitad de una revisión (p. ej. al contestar desde Telegram), se repite al final.
        guard !polling else {
            pollAgain = true
            return
        }
        polling = true
        defer { polling = false }
        repeat {
            pollAgain = false
            await pollOnce()
        } while pollAgain
    }

    private func pollOnce() async {
        do {
            let companies: [PaperclipCompany] = try await api.get("api/companies")
            var seen = UserDefaults.standard.dictionary(forKey: Self.seenKey) as? [String: [String]] ?? [:]
            var total = 0
            for company in PaperclipCompany.watched(companies) {
                let attention: Attention = try await api.get(
                    "api/companies/\(company.id)/attention",
                    query: [URLQueryItem(name: "limit", value: String(Attention.pageLimit))]
                )
                total += attention.deskBadgeCount ?? attention.totalCount ?? attention.items.count
                // El revisor que Paperclip se saltó: si no se pudo despertar, su tarjeta va con las de Decisions.
                let stranded = preferences.wakeStrandedReviewers
                    ? await reviewWaker.check(company, decisions: attention.items) : []
                let items = attention.items + stranded
                let complete = attention.nextCursor == nil
                let review = Self.review(items, complete: complete, previous: seen[company.id])
                await announce(review.fresh, in: company, firstTime: review.firstTime)
                if review.seen != seen[company.id] {
                    seen[company.id] = review.seen
                    // Se guarda por company: si falla la siguiente, lo que ya se avisó de esta no se repite.
                    UserDefaults.standard.set(seen, forKey: Self.seenKey)
                }
                onAttention?(company.id, items, complete)
            }
            pendingCount = total
            signedOut = false
            onSignedIn?()
        } catch PaperclipAPI.APIError.signedOut {
            // Sin sesión (pantalla de inicio) no hay número; se vuelve a intentar en la próxima vuelta.
            pendingCount = 0
            signedOut = true
        } catch {
            // Sin red o con Paperclip reiniciándose: queda lo último que se supo.
        }
        applyBadge()
    }

    /// Una company en una revisión que salió bien (`previous`: lo ya avisado; nil si es la primera vez que la
    /// app la ve). Queda como avisado lo pendiente ahora y, si la lista no vino entera, también lo anterior que
    /// no vino, que puede estar en otra página. Lo que falta en una lista entera ya no está pendiente y se
    /// olvida: si vuelve (p. ej. una tarea que se destraba y se vuelve a trabar), se avisa otra vez. Una
    /// revisión que falla no llega aquí, así que no cuenta como que algo dejó de estar pendiente.
    static func review(
        _ items: [AttentionItem],
        complete: Bool,
        previous: [String]?
    ) -> (fresh: [AttentionItem], firstTime: Bool, seen: [String]) {
        let known = Set(previous ?? [])
        let fresh = items.filter { !known.contains($0.id) }
        let current = items.map(\.id)
        let currentSet = Set(current)
        let otherPages = complete ? [] : (previous ?? []).filter { !currentSet.contains($0) }
        return (fresh, previous == nil, Array((current + otherPages).prefix(seenLimit)))
    }

    /// Lo que llega mientras se mira la ventana no se avisa (salvo que se pida en Ajustes): la barra
    /// lateral ya lo muestra. Igual queda como visto. La primera vez sí, porque se acaba de abrir la app.
    private func announce(_ fresh: [AttentionItem], in company: PaperclipCompany, firstTime: Bool) async {
        guard !fresh.isEmpty, preferences.decisionNotifications,
              firstTime || preferences.notifyWhileLooking || !isLooking()
        else { return }
        if firstTime, fresh.count > Self.individualLimit {
            notifications.show(
                id: "decisions-\(company.id)",
                tag: "decisions-\(company.id)",
                title: company.name ?? "Paperclip",
                body: String(localized: "You have \(fresh.count) pending decisions."),
                href: company.issuePrefix.map { "/\($0)/decisions" }
            )
            return
        }
        for item in fresh {
            let notice = Self.notice(for: item)
            var body = notice.body
            // Una tarea trabada a nombre de un agente lleva el botón para despertarlo, salvo que ya vaya en camino.
            var wake: WakeButton?
            if let target = item.wakeTarget {
                async let progress = resolver.wakeProgress(target)
                let agentName = await resolver.agentName(target.agentId)
                (body, wake) = Self.wakeNotice(body: body, target: target, agentName: agentName, progress: await progress)
            }
            notifications.show(id: item.id, tag: item.id, title: notice.title, body: body, href: notice.href, wake: wake)
        }
    }

    /// Título, texto y enlace del aviso de una decisión.
    static func notice(for item: AttentionItem) -> (title: String, body: String, href: String?) {
        let parts: [String] = [item.originAgentName, item.relatedIssue?.identifier].compactMap { $0 }
        let body: String = item.detail?.promptExcerpt ?? item.subject?.title ?? item.whyNow
            ?? String(localized: "Something is waiting for your decision.")
        return (parts.isEmpty ? "Paperclip" : parts.joined(separator: " · "), body, item.subject?.href ?? item.relatedIssue?.href)
    }

    /// El aviso de una tarea trabada a nombre de un agente: con el botón para despertarlo o, si ya tiene una
    /// corrida en la tarea, con «⏳ Ya va en camino…» y sin el botón. Si no se supo (`progress` nil), con el botón.
    static func wakeNotice(
        body: String,
        target: WakeTarget,
        agentName: String?,
        progress: WakeProgress?
    ) -> (body: String, wake: WakeButton?) {
        guard case let .onTheWay(running)? = progress else {
            return (body, WakeButton(target: target, agentName: agentName))
        }
        return (body + "\n" + WakeText.onTheWay(running: running, target: target, agentName: agentName), nil)
    }

    /// Se apretó «Despertar a …» en un aviso: despierta al agente (solo esta vez, sin reintentos) y cambia el
    /// aviso por lo que respondió Paperclip. Si Paperclip lo saltó o falló, el aviso nuevo trae el botón otra vez.
    func wake(_ button: WakeButton, notificationId: String, href: String?) {
        let target = button.target
        guard !waking.contains(target.issueId) else { return }
        waking.insert(target.issueId)
        Task {
            defer { waking.remove(target.issueId) }
            let outcome = await resolver.wake(target)
            let text = WakeText.result(outcome, target: target, agentName: button.agentName)
            notifications.show(
                id: notificationId,
                tag: notificationId,
                title: text.title,
                body: text.body,
                href: href,
                wake: outcome.allowsRetry ? button : nil,
                sound: false
            )
            refresh()
        }
    }
}
