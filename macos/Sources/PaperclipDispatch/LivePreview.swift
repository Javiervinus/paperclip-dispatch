import Foundation
import OSLog

// «Ver en vivo»: lo que una tarea deja servido para revisarlo (una página, una app web), registrado como
// entregable (`GET /api/issues/{id}/work-products`). Los avisos de la Mac y los mensajes de Telegram de esa tarea
// lo abren: una acción en la Mac y un enlace en el texto en Telegram. Se lee a la defensiva, como Decisions.

/// Un entregable de una tarea. Solo `id` es obligatorio.
struct IssueWorkProduct: Decodable, Sendable {
    let id: String
    /// `preview_url`, `runtime_service`, `pull_request`, `document`…
    let type: String?
    let url: String?
    /// `active`, `ready_for_review`, `closed`, `archived`, `failed`…
    let status: String?
    let isPrimary: Bool?
    let updatedAt: String?

    private enum CodingKeys: String, CodingKey { case id, type, url, status, isPrimary, updatedAt }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        type = try? container.decodeIfPresent(String.self, forKey: .type)
        url = try? container.decodeIfPresent(String.self, forKey: .url)
        status = try? container.decodeIfPresent(String.self, forKey: .status)
        isPrimary = try? container.decodeIfPresent(Bool.self, forKey: .isPrimary)
        updatedAt = try? container.decodeIfPresent(String.self, forKey: .updatedAt)
    }
}

enum LivePreview {
    /// Los entregables que se pueden abrir para ver el trabajo funcionando.
    private static let types: Set<String> = ["preview_url", "runtime_service"]
    /// Los tipos que la app conoce y no abre (`IssueWorkProductType` de Paperclip 2026.1023.0).
    private static let otherTypes: Set<String> = ["pull_request", "branch", "commit", "artifact", "document"]
    /// Los estados en que sigue servido. Los de `gone` ya no; uno que la app no conoce, tampoco.
    private static let live: Set<String> = ["active", "ready_for_review", "approved", "changes_requested", "draft", "merged"]
    private static let gone: Set<String> = ["closed", "archived", "failed"]

    /// La dirección que abre «Ver en vivo»: la del entregable principal (`isPrimary`) o, si ninguno lo es, la
    /// del más reciente. `nil` si ninguno sirve (otro tipo, sin dirección o cerrado).
    static func pick(_ products: [IssueWorkProduct], issueId: String) -> URL? {
        let path = "api/issues/\(issueId)/work-products"
        let candidates = products.compactMap { product -> (product: IssueWorkProduct, url: URL)? in
            guard let type = product.type, types.contains(type) else {
                if !otherTypes.contains(product.type ?? "") {
                    Unexpected.note(path, "\(product.id): unknown type \(product.type ?? "null")")
                }
                return nil
            }
            guard let status = product.status, live.contains(status) else {
                if !gone.contains(product.status ?? "") {
                    Unexpected.note(path, "\(product.id): unknown status \(product.status ?? "null")")
                }
                return nil
            }
            guard let url = url(product.url) else {
                Unexpected.note(path, "\(product.id): \(type) without a web url")
                return nil
            }
            return (product, url)
        }
        let best = candidates.max { lhs, rhs in
            let left = (lhs.product.isPrimary == true, updated(lhs.product))
            let right = (rhs.product.isPrimary == true, updated(rhs.product))
            if left.0 != right.0 { return !left.0 }
            return left.1 < right.1
        }
        return best?.url
    }

    /// Solo direcciones web: un entregable con otra cosa (una ruta de archivo) no se abre desde un aviso.
    static func url(_ raw: String?) -> URL? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
              let url = URL(string: raw), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host() != nil
        else { return nil }
        return url
    }

    /// Una dirección que solo abre en esta Mac (`localhost`, `127.0.0.1`, `::1`): en el teléfono no sirve y
    /// Telegram la rechaza, así que ahí no va el enlace.
    static func isLocal(_ url: URL) -> Bool {
        url.host().map(LocalHost.contains) ?? false
    }

    private static func updated(_ product: IssueWorkProduct) -> Date {
        PaperclipDate.parse(product.updatedAt) ?? .distantPast
    }
}

/// Lee «Ver en vivo» de una tarea, solo cuando hace falta: al armar el aviso o el mensaje de una tarea, y al
/// volver a editar ese mensaje por otra razón. El aviso de la Mac y el mensaje de Telegram de una misma
/// decisión salen casi juntos: comparten la lectura (`reuseFor`) en vez de pedirla dos veces.
@MainActor
final class LivePreviews {
    enum Lookup: Equatable {
        case found(URL)
        case none
        /// No se pudo leer (sin red, Paperclip reiniciándose…): el aviso sale igual, sin «Ver en vivo».
        case failed

        var url: URL? { if case let .found(url) = self { url } else { nil } }
    }

    /// Lo leído de una tarea vale este tiempo: lo justo para el aviso de la Mac y el mensaje de Telegram de la
    /// misma vuelta, o los pasos seguidos de una tarjeta.
    private static let reuseFor: TimeInterval = 30
    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "PaperclipDispatch", category: "live-preview")

    private let api: PaperclipAPI
    private var recent: [String: (lookup: Lookup, at: Date)] = [:]
    private var reading: [String: Task<Lookup, Never>] = [:]

    init(api: PaperclipAPI) {
        self.api = api
    }

    func lookup(issueId: String?) async -> Lookup {
        guard let issueId else { return .none }
        if let cached = recent[issueId], Date().timeIntervalSince(cached.at) < Self.reuseFor { return cached.lookup }
        if let task = reading[issueId] { return await task.value }
        let task = Task { await read(issueId) }
        reading[issueId] = task
        let lookup = await task.value
        reading[issueId] = nil
        let now = Date()
        recent = recent.filter { now.timeIntervalSince($0.value.at) < Self.reuseFor }
        recent[issueId] = (lookup, now)
        return lookup
    }

    /// Para un aviso nuevo: la dirección, o `nil` si no hay o no se pudo leer.
    func url(issueId: String?) async -> URL? {
        await lookup(issueId: issueId).url
    }

    /// Las de varias tareas a la vez (los avisos nuevos de una vuelta), para no esperarlas una tras otra.
    func urls(issueIds: [String]) async -> [String: URL] {
        await withTaskGroup(of: (String, URL?).self) { group in
            for issueId in Set(issueIds) {
                group.addTask { await (issueId, self.url(issueId: issueId)) }
            }
            var found: [String: URL] = [:]
            for await (issueId, url) in group { found[issueId] = url }
            return found
        }
    }

    private func read(_ issueId: String) async -> Lookup {
        do {
            let products: [Lossy<IssueWorkProduct>] = try await api.get("api/issues/\(issueId)/work-products")
            let url = LivePreview.pick(products.compactMap(\.value), issueId: issueId)
            Self.log.notice("\(issueId, privacy: .public): \(url == nil ? "no preview" : "preview", privacy: .public)")
            return url.map(Lookup.found) ?? .none
        } catch {
            Self.log.notice("\(issueId, privacy: .public): work products unreadable (\(error.localizedDescription, privacy: .public))")
            return .failed
        }
    }
}
