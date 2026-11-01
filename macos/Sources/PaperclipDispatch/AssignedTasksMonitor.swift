import Foundation
import OSLog

/// Avisa cuando un agente le asigna una tarea al usuario: un aviso de la Mac y un mensaje de Telegram. Corre
/// dentro de cada revisión de Decisions (`DecisionsMonitor`), con una sola lectura de tareas por company; lo
/// demás (quién la asignó, el nombre del agente y del proyecto) se lee solo para una tarea nueva y queda en
/// memoria. No suma al número del Dock, que es el de Decisions.
///
/// - Lo que se asigna el propio usuario no avisa (lo dice la actividad de la tarea).
/// - La primera vez que ve una company avisa lo que ya tenía, como Decisions: hasta `individualLimit` una por
///   una y, si son más, un solo aviso con el total. Lo avisado se recuerda, también al reabrir la app.
/// - Si deja de estar a su nombre (se cerró o se reasignó), el mensaje de Telegram se edita para decirlo. El
///   aviso de la Mac queda como el de una decisión que dejó de estar pendiente.
/// - Responder al mensaje de Telegram deja un comentario en la tarea.
/// - Si la tarea tiene algo servido para verlo, el aviso y el mensaje llevan «Ver en vivo» (`LivePreviews`); al
///   cerrarse, el mensaje lo pierde.
@MainActor
final class AssignedTasksMonitor {
    private static let individualLimit = 3
    /// Lo ya visto, por company.
    private static let seenKey = "seenAssignedTasks"
    /// Los mensajes de Telegram de cada tarea, para editarlos al cerrarse y para comentar al responderlos.
    private static let messagesKey = "assignedTaskMessages"
    /// Las abiertas, como la bandeja «Mine» sin las terminadas.
    private static let openStatuses = "backlog,todo,in_progress,in_review,blocked"
    /// Si la lista trae esto o más, puede que no haya entrado todo.
    private static let pageLimit = 500
    /// Tope de ids recordados por company, como en Decisions.
    private static let seenLimit = 1000
    /// Si la actividad de una tarea no se puede leer tantas veces seguidas, se avisa sin decir quién la asignó.
    private static let activityAttempts = 3
    /// Cuántas actividades se leen a la vez (la primera vez puede haber muchas tareas).
    private static let activityBatch = 6
    /// Cuánto se recuerda el mensaje de una tarea que ya no es del usuario (para comentar al responderlo).
    private static let keepClosed: TimeInterval = 7 * 24 * 60 * 60
    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "PaperclipDispatch", category: "assigned-tasks")

    struct SentTask: Codable {
        var companyId: String
        var chatId: Int64
        var messageId: Int
        var html: String
        var identifier: String?
        var href: String?
        /// El usuario a cuyo nombre estaba, para saber al final si sigue siéndolo.
        var userId: String?
        /// Cómo terminó, ya leído, mientras falta editar el mensaje (p. ej. con el bot apagado).
        var ending: AssignedTaskEnding?
        /// Ya se editó el mensaje para decir cómo terminó.
        var closedAt: Date?
    }

    /// Para mandar y editar los mensajes; sin bot vinculado, solo avisa en la Mac.
    weak var telegram: TelegramChannel? {
        didSet {
            telegram?.onReply = { [weak self] replied, text, messageId in
                await self?.comment(text, replyingTo: replied, messageId: messageId) ?? false
            }
        }
    }

    /// «Ver en vivo» de cada tarea nueva, solo al avisarla.
    var previews: LivePreviews?

    private let api: PaperclipAPI
    private let resolver: DecisionResolver
    private let preferences: Preferences
    private let notifications: NotificationBridge
    private let isLooking: () -> Bool
    private let defaults: UserDefaults
    /// Por id de tarea.
    private var messages: [String: SentTask]
    private var agentNames: [String: String] = [:]
    /// Por tarea, las veces seguidas que no se pudo leer su actividad.
    private var activityFailures: [String: Int] = [:]
    /// Por company, el nombre de cada proyecto.
    private var projectNames: [String: [String: String]] = [:]

    init(
        api: PaperclipAPI,
        resolver: DecisionResolver,
        preferences: Preferences,
        notifications: NotificationBridge,
        defaults: UserDefaults = .standard,
        isLooking: @escaping () -> Bool
    ) {
        self.api = api
        self.resolver = resolver
        self.preferences = preferences
        self.notifications = notifications
        self.defaults = defaults
        self.isLooking = isLooking
        messages = defaults.data(forKey: Self.messagesKey)
            .flatMap { try? JSONDecoder().decode([String: SentTask].self, from: $0) } ?? [:]
    }

    /// Una company en una revisión de Decisions que salió bien. Si algo falla, queda lo último que se supo y se
    /// vuelve a intentar en la próxima. `covered`: las tareas que ya avisa Decisions en esta vuelta (p. ej. una
    /// revisión que un agente le pasa al usuario), que no se avisan dos veces.
    func review(_ company: PaperclipCompany, covered: Set<String> = []) async {
        let issues: [AssignedIssue]
        let complete: Bool
        do {
            let page: [Lossy<AssignedIssue>] = try await api.get(
                "api/companies/\(company.id)/issues",
                query: [
                    URLQueryItem(name: "assigneeUserId", value: "me"),
                    URLQueryItem(name: "status", value: Self.openStatuses),
                    URLQueryItem(name: "limit", value: String(Self.pageLimit)),
                ]
            )
            issues = page.compactMap(\.value)
            complete = page.count < Self.pageLimit
        } catch {
            return
        }
        var seenAll = defaults.dictionary(forKey: Self.seenKey) as? [String: [String]] ?? [:]
        let previous = seenAll[company.id]
        let known = Set(previous ?? [])
        let current = Set(issues.map(\.id))
        let unseen = issues.filter { !known.contains($0.id) }

        // Las nuevas: quién la asignó. Con el ajuste apagado no se lee nada: quedan como vistas. Si la actividad
        // no se pudo leer, no cuenta como vista y se reintenta en la próxima (unas pocas veces).
        var fresh: [(issue: AssignedIssue, assigner: TaskAssigner)] = []
        var unresolved: Set<String> = []
        if preferences.taskNotifications {
            let assigners = await assigners(of: unseen.filter { !covered.contains($0.id) })
            for issue in unseen {
                if covered.contains(issue.id) {
                    Self.log.notice("\(issue.identifier ?? issue.id, privacy: .public): already in Decisions, no notice")
                    continue
                }
                guard let assigner = assigners[issue.id] else {
                    unresolved.insert(issue.id)
                    continue
                }
                if case let .user(id) = assigner, id == issue.assigneeUserId {
                    Self.log.notice("\(issue.identifier ?? issue.id, privacy: .public): self-assigned, no notice")
                    continue
                }
                fresh.append((issue, assigner))
            }
            if !fresh.isEmpty { await announce(fresh, in: company, firstTime: previous == nil) }
        } else if !unseen.isEmpty {
            Self.log.notice("\(unseen.count, privacy: .public) new task(s), notifications are off")
        }

        // Queda como visto lo de ahora; si la lista no vino entera, también lo anterior que no vino. Lo que
        // falta en una lista entera se olvida: si vuelve a su nombre, se avisa otra vez.
        let otherPages = complete ? [] : (previous ?? []).filter { !current.contains($0) }
        let seen = Array((issues.map(\.id).filter { !unresolved.contains($0) } + otherPages).prefix(Self.seenLimit))
        if seen != previous {
            seenAll[company.id] = seen
            defaults.set(seenAll, forKey: Self.seenKey)
        }
        if complete { await closeGone(companyId: company.id, current: current) }
        prune()
    }

    /// Quién asignó cada una, leyendo su actividad de a `activityBatch` a la vez. Falta la que no se pudo leer,
    /// salvo que ya falló `activityAttempts` veces: esa queda como `.unknown` y se avisa igual.
    private func assigners(of issues: [AssignedIssue]) async -> [String: TaskAssigner] {
        var result: [String: TaskAssigner] = [:]
        for start in stride(from: 0, to: issues.count, by: Self.activityBatch) {
            let batch = issues[start..<min(start + Self.activityBatch, issues.count)]
            let found = await withTaskGroup(of: (String, TaskAssigner?).self) { group in
                for issue in batch {
                    group.addTask { await (issue.id, self.assigner(of: issue)) }
                }
                var found: [(String, TaskAssigner?)] = []
                for await item in group { found.append(item) }
                return found
            }
            for (id, assigner) in found {
                if let assigner {
                    activityFailures[id] = nil
                    result[id] = assigner
                } else {
                    let failures = (activityFailures[id] ?? 0) + 1
                    activityFailures[id] = failures
                    if failures >= Self.activityAttempts { result[id] = .unknown }
                }
            }
        }
        return result
    }

    /// `nil` si no se pudo leer la actividad.
    private func assigner(of issue: AssignedIssue) async -> TaskAssigner? {
        guard let userId = issue.assigneeUserId else { return .unknown }
        guard let activity: [Lossy<IssueActivityEntry>] = try? await api.get("api/issues/\(issue.id)/activity")
        else { return nil }
        return TaskAssigner.of(activity.compactMap(\.value), assignedTo: userId)
    }

    private func announce(_ fresh: [(issue: AssignedIssue, assigner: TaskAssigner)], in company: PaperclipCompany, firstTime: Bool) async {
        // En la Mac, como Decisions: con la ventana al frente no, salvo la primera vez o si se pidió.
        let mac = firstTime || preferences.notifyWhileLooking || !isLooking()
        if firstTime, fresh.count > Self.individualLimit {
            let text = AssignedTaskFormat.summary(fresh.count)
            let href = company.issuePrefix.map { "/\($0)/inbox/mine" }
            Self.log.notice("first look: \(fresh.count, privacy: .public) tasks, one summary")
            if mac {
                notifications.show(
                    id: "assigned-tasks-\(company.id)",
                    tag: "assigned-tasks-\(company.id)",
                    title: company.name ?? "Paperclip",
                    body: text,
                    href: href
                )
            }
            if let telegram, telegram.noticeChatId != nil {
                _ = await telegram.postNotice(TelegramFormat.escape(text), href: href)
            }
            return
        }
        for (issue, assigner) in fresh {
            let assignerName: String? = if case let .agent(id) = assigner { await agentName(id) } else { nil }
            let notice = AssignedTaskFormat.notice(
                for: issue,
                assignerName: assignerName,
                projectName: await projectName(issue.projectId, companyId: company.id),
                prefix: company.issuePrefix
            )
            let preview = await previews?.url(issueId: issue.id)
            Self.log.notice("\(issue.identifier ?? issue.id, privacy: .public): notice (mac: \(mac, privacy: .public))")
            if mac {
                let text = AssignedTaskFormat.mac(notice)
                notifications.show(
                    id: "task-\(issue.id)", tag: "task-\(issue.id)", title: text.title, body: text.body, href: notice.href,
                    preview: preview
                )
            }
            await sendToTelegram(notice, companyId: company.id, userId: issue.assigneeUserId, preview: preview)
        }
    }

    private func sendToTelegram(_ notice: AssignedTaskNotice, companyId: String, userId: String?, preview: URL?) async {
        guard let telegram, let chatId = telegram.noticeChatId else { return }
        let html = AssignedTaskFormat.telegram(notice)
        guard let messageId = await telegram.postNotice(html, href: notice.href, preview: preview) else { return }
        messages[notice.issueId] = SentTask(
            companyId: companyId, chatId: chatId, messageId: messageId, html: html,
            identifier: notice.identifier, href: notice.href, userId: userId
        )
        save()
    }

    /// Las que tenían mensaje y ya no están a su nombre: se lee cómo terminaron y se dice en el mensaje. El
    /// mensaje queda cerrado solo cuando se pudo editar; si el bot está apagado, se edita cuando vuelva.
    private func closeGone(companyId: String, current: Set<String>) async {
        for (issueId, sent) in messages
        where sent.companyId == companyId && sent.closedAt == nil && !current.contains(issueId) {
            var ending = sent.ending
            if ending == nil {
                guard let read = await self.ending(of: issueId, userId: sent.userId) else { continue }
                ending = read
                messages[issueId]?.ending = read
                save()
                Self.log.notice("\(sent.identifier ?? issueId, privacy: .public): no longer theirs (\(String(describing: read), privacy: .public))")
            }
            guard let ending, let telegram, let chatId = telegram.noticeChatId else { continue }
            // Otro chat (se vinculó otro bot): el mensaje ya no está a la vista; se da por cerrado.
            if chatId == sent.chatId {
                let html = sent.html + "\n\n" + AssignedTaskFormat.ending(ending)
                guard await telegram.editNotice(sent.messageId, html: html, href: sent.href) else { continue }
            }
            messages[issueId]?.closedAt = Date()
            save()
        }
    }

    /// `nil` si no se pudo saber (sin red) o si sigue a su nombre (salió de la lista por un estado que no se
    /// pide): se vuelve a mirar en la próxima revisión.
    private func ending(of issueId: String, userId: String?) async -> AssignedTaskEnding? {
        do {
            let issue: AssignedIssue = try await api.get("api/issues/\(issueId)")
            switch issue.status {
            case "done": return .done
            case "cancelled": return .cancelled
            default:
                if let agentId = issue.assigneeAgentId { return .reassignedToAgent(await agentName(agentId)) }
                if let userId, issue.assigneeUserId == userId { return nil }
                return .notYours
            }
        } catch PaperclipAPI.APIError.http(404, _) {
            return .deleted
        } catch {
            return nil
        }
    }

    /// Responder en Telegram al mensaje de una tarea deja un comentario en ella. `false` si el mensaje no es de
    /// una tarea.
    private func comment(_ text: String, replyingTo replied: Int, messageId: Int) async -> Bool {
        guard let telegram, let chatId = telegram.noticeChatId,
              let (issueId, sent) = messages.first(where: { $0.value.messageId == replied && $0.value.chatId == chatId })
        else { return false }
        do {
            try await resolver.comment(text, issueId: issueId)
            Self.log.notice("\(sent.identifier ?? issueId, privacy: .public): comment from Telegram")
            await telegram.replyNotice(
                String(localized: "💬 Comment added to \(sent.identifier ?? String(localized: "the task"))."),
                to: messageId
            )
        } catch {
            await telegram.replyNotice(String(localized: "Couldn’t comment: \(error.localizedDescription)"), to: messageId)
        }
        return true
    }

    private func agentName(_ id: String) async -> String? {
        if let name = agentNames[id] { return name }
        let name = await resolver.agentName(id)
        if let name { agentNames[id] = name }
        return name
    }

    /// Los proyectos de la company se leen una vez y quedan en memoria; uno nuevo hace volver a leerlos.
    private func projectName(_ projectId: String?, companyId: String) async -> String? {
        guard let projectId else { return nil }
        if let name = projectNames[companyId]?[projectId] { return name }
        guard let projects: [Lossy<ProjectSummary>] = try? await api.get("api/companies/\(companyId)/projects")
        else { return nil }
        var names: [String: String] = [:]
        for project in projects.compactMap(\.value) {
            if let name = project.name, !name.isEmpty { names[project.id] = name }
        }
        projectNames[companyId] = names
        return names[projectId]
    }

    private func prune() {
        let now = Date()
        let kept = messages.filter { _, sent in sent.closedAt.map { now.timeIntervalSince($0) < Self.keepClosed } ?? true }
        guard kept.count != messages.count else { return }
        messages = kept
        save()
    }

    private func save() {
        defaults.set(try? JSONEncoder().encode(messages), forKey: Self.messagesKey)
    }

    private struct ProjectSummary: Decodable {
        let id: String
        let name: String?
    }
}
