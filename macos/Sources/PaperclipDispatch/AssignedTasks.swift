import Foundation

// Lo que se lee de las tareas a nombre del usuario (`GET /api/companies/{id}/issues?assigneeUserId=me`, la
// bandeja «Mine» de Paperclip) y de su actividad (`GET /api/issues/{id}/activity`). Decisions no las trae: los
// agentes le asignan una tarea a una persona cuando el trabajo lo tiene que hacer ella. Se lee a la defensiva,
// como Decisions: un campo nuevo o con otra forma no tapa al resto.

/// Una tarea de la lista. Solo `id` es obligatorio.
struct AssignedIssue: Decodable, Sendable {
    let id: String
    let identifier: String?
    let title: String?
    let description: String?
    let status: String?
    let assigneeUserId: String?
    let assigneeAgentId: String?
    let projectId: String?

    private enum CodingKeys: String, CodingKey {
        case id, identifier, title, description, status, assigneeUserId, assigneeAgentId, projectId
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        identifier = try? container.decodeIfPresent(String.self, forKey: .identifier)
        title = try? container.decodeIfPresent(String.self, forKey: .title)
        description = try? container.decodeIfPresent(String.self, forKey: .description)
        status = try? container.decodeIfPresent(String.self, forKey: .status)
        assigneeUserId = try? container.decodeIfPresent(String.self, forKey: .assigneeUserId)
        assigneeAgentId = try? container.decodeIfPresent(String.self, forKey: .assigneeAgentId)
        projectId = try? container.decodeIfPresent(String.self, forKey: .projectId)
    }

    /// Como arma Paperclip 2026.1023.0 el enlace de una tarea en Decisions: `/<prefijo>/issues/<identificador o id>`.
    func href(prefix: String?) -> String? {
        guard let prefix else { return nil }
        return "/\(prefix)/issues/\(identifier ?? id)"
    }
}

/// Una entrada de la actividad de una tarea. Paperclip 2026.1023.0 no guarda quién asignó una tarea: lo dice
/// la actividad, en la entrada que la creó o en la que cambió `assigneeUserId`.
struct IssueActivityEntry: Decodable, Sendable {
    let action: String?
    /// `agent`, `user` o `system`.
    let actorType: String?
    let actorId: String?
    let agentId: String?
    let createdAt: String?
    /// A quién quedó asignada con este cambio, si lo cambió.
    let assignedUserId: String?
    /// Si este cambio tocó a quién está asignada (a una persona o a un agente).
    let changesAssignee: Bool

    private enum CodingKeys: String, CodingKey { case action, actorType, actorId, agentId, createdAt, details }
    private enum DetailKeys: String, CodingKey { case changes }
    private enum ChangeKeys: String, CodingKey { case assigneeUserId, assigneeAgentId }
    private enum ValueKeys: String, CodingKey { case to }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        action = try? container.decodeIfPresent(String.self, forKey: .action)
        actorType = try? container.decodeIfPresent(String.self, forKey: .actorType)
        actorId = try? container.decodeIfPresent(String.self, forKey: .actorId)
        agentId = try? container.decodeIfPresent(String.self, forKey: .agentId)
        createdAt = try? container.decodeIfPresent(String.self, forKey: .createdAt)
        // `details.changes.assigneeUserId.to` en un `issue.updated`.
        let changes = try? container.nestedContainer(keyedBy: DetailKeys.self, forKey: .details)
            .nestedContainer(keyedBy: ChangeKeys.self, forKey: .changes)
        assignedUserId = try? changes?.nestedContainer(keyedBy: ValueKeys.self, forKey: .assigneeUserId)
            .decodeIfPresent(String.self, forKey: .to)
        changesAssignee = changes.map { $0.contains(.assigneeUserId) || $0.contains(.assigneeAgentId) } ?? false
    }
}

/// Quién dejó la tarea a nombre del usuario.
enum TaskAssigner: Equatable, Sendable {
    case agent(id: String)
    case user(id: String)
    /// Paperclip mismo (una rutina, una recuperación).
    case system
    /// La actividad no lo dice.
    case unknown

    /// El cambio más reciente que dejó la tarea a nombre de `userId`; si no hay, el que la creó (ya nació a su
    /// nombre). `activity` viene de la más nueva a la más vieja, pero se ordena igual por si acaso.
    static func of(_ activity: [IssueActivityEntry], assignedTo userId: String) -> TaskAssigner {
        let newestFirst = activity.sorted { ($0.createdAt ?? "") > ($1.createdAt ?? "") }
        // Si el asignado cambió después de crearla pero la actividad no dice quién se la dio, no se sabe: se
        // avisa sin decir quién (antes que callar una tarea que un agente le devolvió).
        let entry = newestFirst.first { $0.action == "issue.updated" && $0.assignedUserId == userId }
            ?? (newestFirst.contains { $0.changesAssignee } ? nil : newestFirst.first { $0.action == "issue.created" })
        guard let entry else { return .unknown }
        switch entry.actorType {
        case "agent":
            guard let id = entry.agentId ?? entry.actorId else { return .unknown }
            return .agent(id: id)
        case "user":
            guard let id = entry.actorId else { return .unknown }
            return .user(id: id)
        default:
            return .system
        }
    }
}

/// Lo que se le cuenta al usuario de una tarea suya.
struct AssignedTaskNotice: Sendable {
    let issueId: String
    let identifier: String?
    let title: String?
    /// El principio de la descripción, en una línea.
    let excerpt: String?
    /// El agente que se la asignó, si fue un agente y se sabe su nombre.
    let assignerName: String?
    let projectName: String?
    let href: String?
}

/// Cómo terminó una tarea que ya no está a nombre del usuario.
enum AssignedTaskEnding: Codable, Equatable, Sendable {
    case done
    case cancelled
    /// A un agente; `nil` si no se sabe su nombre.
    case reassignedToAgent(String?)
    /// A otra persona, o a nadie.
    case notYours
    case deleted
}

/// Los textos de los avisos de tareas asignadas, en la Mac y en Telegram.
enum AssignedTaskFormat {
    /// Lo que entra del principio de la descripción en el aviso de la Mac y en Telegram.
    private static let macExcerptLimit = 180
    private static let telegramExcerptLimit = 400

    static func notice(
        for issue: AssignedIssue,
        assignerName: String?,
        projectName: String?,
        prefix: String?
    ) -> AssignedTaskNotice {
        AssignedTaskNotice(
            issueId: issue.id,
            identifier: issue.identifier,
            title: issue.title,
            excerpt: excerpt(issue.description, limit: telegramExcerptLimit),
            assignerName: assignerName,
            projectName: projectName,
            href: issue.href(prefix: prefix)
        )
    }

    static func headline(_ notice: AssignedTaskNotice) -> String {
        let identifier = notice.identifier ?? String(localized: "a task")
        guard let title = notice.title, !title.isEmpty else {
            return String(localized: "📌 You were assigned \(identifier)")
        }
        return String(localized: "📌 You were assigned \(identifier) · \(title)")
    }

    /// «Asignada por Operaciones · Sitio web».
    static func byline(_ notice: AssignedTaskNotice) -> String? {
        let parts = [notice.assignerName.map { String(localized: "Assigned by \($0)") }, notice.projectName]
            .compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Título y texto del aviso de la Mac.
    static func mac(_ notice: AssignedTaskNotice) -> (title: String, body: String) {
        let body = [byline(notice), notice.excerpt.map { excerpt($0, limit: macExcerptLimit) ?? $0 }]
            .compactMap { $0 }
            .joined(separator: "\n")
        return (headline(notice), body.isEmpty ? String(localized: "Open it in Paperclip.") : body)
    }

    /// El mensaje de Telegram (HTML de la Bot API).
    static func telegram(_ notice: AssignedTaskNotice) -> String {
        var lines = ["<b>\(TelegramFormat.escape(headline(notice)))</b>"]
        if let byline = byline(notice) { lines.append("<i>\(TelegramFormat.escape(byline))</i>") }
        if let excerpt = notice.excerpt {
            lines.append("<blockquote expandable>\(TelegramFormat.markdown(excerpt))</blockquote>")
        }
        lines.append(replyHint)
        return lines.joined(separator: "\n")
    }

    /// La última línea del mensaje de Telegram: «Ver en vivo» va justo antes, junto a la descripción.
    static var replyHint: String { String(localized: "<i>Reply to this message to comment on the task.</i>") }

    /// Lo que se suma al mensaje de Telegram cuando la tarea deja de estar a nombre del usuario.
    static func ending(_ ending: AssignedTaskEnding) -> String {
        switch ending {
        case .done: String(localized: "✅ <i>Closed: it’s done.</i>")
        case .cancelled: String(localized: "☑️ <i>Closed: it was cancelled.</i>")
        case let .reassignedToAgent(name?):
            String(localized: "↪️ <i>Reassigned to \(TelegramFormat.escape(name)).</i>")
        case .reassignedToAgent(nil): String(localized: "↪️ <i>Reassigned to an agent.</i>")
        case .notYours: String(localized: "↪️ <i>No longer assigned to you.</i>")
        case .deleted: String(localized: "☑️ <i>It no longer exists in Paperclip.</i>")
        }
    }

    /// La primera vez, si son más de las que se avisan una por una.
    static func summary(_ count: Int) -> String {
        String(localized: "📌 You have \(count) tasks assigned to you.")
    }

    /// El principio de un texto en una línea, cortado en un espacio.
    static func excerpt(_ text: String?, limit: Int) -> String? {
        guard let text else { return nil }
        // Sin las marcas de Markdown al principio de cada línea (títulos, listas, citas): en una sola línea, un
        // «##» pondría todo en negrita en Telegram.
        let line = text.split(whereSeparator: \.isNewline)
            .map { String($0).replacing(#/^\s*(#{1,6}|>|[-*+]|\d+\.)\s+/#, with: "") }
            .joined(separator: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard !line.isEmpty else { return nil }
        guard line.count > limit else { return line }
        let cut = line.prefix(limit)
        let end = cut.lastIndex(of: " ") ?? cut.endIndex
        return String(cut[..<end]) + "…"
    }
}
