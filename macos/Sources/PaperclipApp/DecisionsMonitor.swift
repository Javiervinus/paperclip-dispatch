import AppKit

/// Revisa Decisions de Paperclip cada minuto, pone el número de pendientes en el Dock y avisa con un aviso
/// de macOS cuando llega una decisión nueva. Lo hace la app y no la página, porque macOS frena las páginas
/// que no se ven: así sigue avisando con la ventana cerrada (Cmd+W).
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
    private static let seenLimit = 500

    /// Lo pendiente de una company en cada revisión que salió bien. `complete` es falso si no entró todo
    /// en una página: lo que falta no está resuelto.
    var onAttention: ((_ companyId: String, _ items: [AttentionItem], _ complete: Bool) -> Void)?

    private let api: PaperclipAPI
    private let preferences: Preferences
    private let notifications: NotificationBridge
    private let isLooking: () -> Bool
    private var timer: Timer?
    private var polling = false
    private var pollAgain = false
    private var pendingCount = 0

    init(
        api: PaperclipAPI,
        preferences: Preferences,
        notifications: NotificationBridge,
        isLooking: @escaping () -> Bool
    ) {
        self.api = api
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
            let active = companies.filter { $0.status == "active" }
            var seen = UserDefaults.standard.dictionary(forKey: Self.seenKey) as? [String: [String]] ?? [:]
            var total = 0
            for company in active.isEmpty ? companies : active {
                let attention: Attention = try await api.get(
                    "api/companies/\(company.id)/attention",
                    query: [URLQueryItem(name: "limit", value: String(Attention.pageLimit))]
                )
                total += attention.totalCount ?? attention.items.count
                let previous = seen[company.id]
                let known = Set(previous ?? [])
                announce(attention.items.filter { !known.contains($0.id) }, in: company, firstTime: previous == nil)
                let current = attention.items.map(\.id)
                let currentSet = Set(current)
                let older = (previous ?? []).filter { !currentSet.contains($0) }
                seen[company.id] = Array((current + older).prefix(Self.seenLimit))
                onAttention?(company.id, attention.items, attention.nextCursor == nil)
            }
            UserDefaults.standard.set(seen, forKey: Self.seenKey)
            pendingCount = total
        } catch PaperclipAPI.APIError.signedOut {
            // Sin sesión (pantalla de inicio) no hay número; se vuelve a intentar en la próxima vuelta.
            pendingCount = 0
        } catch {
            // Sin red o con Paperclip reiniciándose: queda lo último que se supo.
        }
        applyBadge()
    }

    /// Lo que llega mientras se mira la ventana no se avisa (salvo que se pida en Ajustes): la barra
    /// lateral ya lo muestra. Igual queda como visto. La primera vez sí, porque se acaba de abrir la app.
    private func announce(_ fresh: [AttentionItem], in company: PaperclipCompany, firstTime: Bool) {
        guard !fresh.isEmpty, preferences.decisionNotifications,
              firstTime || preferences.notifyWhileLooking || !isLooking()
        else { return }
        if firstTime, fresh.count > Self.individualLimit {
            notifications.show(
                id: "decisions-\(company.id)",
                tag: "decisions-\(company.id)",
                title: company.name ?? "Paperclip",
                body: "Tienes \(fresh.count) decisiones pendientes.",
                href: company.issuePrefix.map { "/\($0)/decisions" }
            )
            return
        }
        for item in fresh {
            let parts: [String] = [item.originAgentName, item.relatedIssue?.identifier].compactMap { $0 }
            let body: String = item.detail?.promptExcerpt ?? item.subject?.title ?? item.whyNow
                ?? "Algo espera tu decisión."
            notifications.show(
                id: item.id,
                tag: item.id,
                title: parts.isEmpty ? "Paperclip" : parts.joined(separator: " · "),
                body: body,
                href: item.subject?.href ?? item.relatedIssue?.href
            )
        }
    }
}
