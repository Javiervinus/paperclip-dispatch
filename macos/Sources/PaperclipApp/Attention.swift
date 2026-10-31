import Foundation

// Lo que se lee de Decisions (`GET /api/companies/{id}/attention`). Todo es opcional y se lee a la
// defensiva: un campo nuevo o con otra forma en una versión de Paperclip no tapa al resto.

struct PaperclipCompany: Decodable, Sendable {
    let id: String
    let name: String?
    let status: String?
    let issuePrefix: String?
}

struct Attention: Decodable, Sendable {
    /// Paperclip pagina de a 50 por defecto; se piden hasta 100.
    static let pageLimit = 100

    let totalCount: Int?
    let items: [AttentionItem]
    /// Hay más en otra página: lo que no vino no está resuelto, solo no entró.
    let nextCursor: String?

    private enum CodingKeys: String, CodingKey { case totalCount, items, nextCursor }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        totalCount = try? container.decodeIfPresent(Int.self, forKey: .totalCount)
        nextCursor = try? container.decodeIfPresent(String.self, forKey: .nextCursor)
        // Un elemento de un tipo nuevo que no se entienda no tapa a los demás.
        items = (try? container.decodeIfPresent([Lossy<AttentionItem>].self, forKey: .items))?.compactMap(\.value) ?? []
    }
}

struct AttentionItem: Decodable, Sendable {
    let id: String
    /// approval, decision, issue_thread_interaction, failed_run, budget_alert…
    let sourceKind: String?
    let subject: AttentionReference?
    let relatedIssue: AttentionReference?
    let project: AttentionProject?
    let detail: AttentionDetail?
    /// Si Paperclip deja responderla sin abrir la página (p. ej. no las aprobaciones de board).
    let inlineResolvable: Bool
    let originAgentName: String?
    let whyNow: String?

    private enum CodingKeys: String, CodingKey {
        case id, sourceKind, subject, relatedIssue, project, detail, inlineResolvable, originAgentName, whyNow
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        sourceKind = try? container.decodeIfPresent(String.self, forKey: .sourceKind)
        subject = try? container.decodeIfPresent(AttentionReference.self, forKey: .subject)
        relatedIssue = try? container.decodeIfPresent(AttentionReference.self, forKey: .relatedIssue)
        project = try? container.decodeIfPresent(AttentionProject.self, forKey: .project)
        detail = try? container.decodeIfPresent(AttentionDetail.self, forKey: .detail)
        inlineResolvable = (try? container.decodeIfPresent(Bool.self, forKey: .inlineResolvable)) ?? false
        originAgentName = try? container.decodeIfPresent(String.self, forKey: .originAgentName)
        whyNow = try? container.decodeIfPresent(String.self, forKey: .whyNow)
    }

    /// La tarea donde vive, para comentar en ella.
    var issueId: String? { subject?.metadata?.issueId ?? relatedIssue?.id }
}

struct AttentionReference: Decodable, Sendable {
    let id: String?
    let identifier: String?
    let title: String?
    let href: String?
    let metadata: AttentionMetadata?

    private enum CodingKeys: String, CodingKey { case id, identifier, title, href, metadata }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try? container.decodeIfPresent(String.self, forKey: .id)
        identifier = try? container.decodeIfPresent(String.self, forKey: .identifier)
        title = try? container.decodeIfPresent(String.self, forKey: .title)
        href = try? container.decodeIfPresent(String.self, forKey: .href)
        metadata = try? container.decodeIfPresent(AttentionMetadata.self, forKey: .metadata)
    }
}

/// De `metadata` solo se usa esto; el resto cambia según el tipo.
struct AttentionMetadata: Decodable, Sendable {
    /// En las interacciones de una tarea: request_confirmation, ask_user_questions…
    let kind: String?
    let issueId: String?

    private enum CodingKeys: String, CodingKey { case kind, issueId }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try? container.decodeIfPresent(String.self, forKey: .kind)
        issueId = try? container.decodeIfPresent(String.self, forKey: .issueId)
    }
}

struct AttentionProject: Decodable, Sendable {
    let name: String?
}

struct AttentionDetail: Decodable, Sendable {
    let promptExcerpt: String?
}

/// Un elemento que no se pueda leer queda en `nil` en vez de romper la lista entera.
struct Lossy<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}

extension Lossy: Sendable where Value: Sendable {}

/// Cualquier valor de JSON, para saber si un campo vino sin leer su forma.
struct PresentValue: Decodable, Sendable {
    init(from decoder: Decoder) throws {}
}
