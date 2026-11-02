import Foundation
import FoundationModels
import WebKit

/// La IA integrada de Chrome (`window.LanguageModel`, language-model.js) atendida con el modelo de Apple de
/// esta Mac (Foundation Models), para los plugins de Paperclip que escriben con ella. Solo le contesta a este
/// Paperclip, y cada página empieza sin sesiones (`reset`).
///
/// Con `responseConstraint`, el modelo cumple la forma del JSON Schema pero no lo lee en el prompt: así se
/// confunde menos (con el de Oficina global, 2 de 15 finales de conversación buenos leyéndolo y 9 de 15 sin
/// leerlo, contados con el validador del propio plugin). Las guías de texto (`pattern` y los largos) quedan
/// fuera: Foundation Models falla con cualquier `pattern` en macOS 26.5, y la página igual revisa lo que recibe.
@MainActor
final class LanguageModelBridge: NSObject, WKScriptMessageHandlerWithReply {
    static let handlerName = "paperclipDispatchLanguageModel"
    /// Cada cuánto se mira si una sesión ocupada ya se liberó.
    private static let busyPollInterval: Duration = .milliseconds(50)

    /// Un error como lo espera la página: el nombre del DOMException (o TypeError) y su mensaje.
    private struct Failure: Error {
        let name: String
        let message: String

        static let notAllowed = Failure(name: "NotAllowedError", message: "Only Paperclip can use the model.")
        static let unavailable = Failure(name: "NotSupportedError", message: "Apple Intelligence is not available on this Mac.")
        static let destroyed = Failure(name: "InvalidStateError", message: "The session was destroyed.")
        static let aborted = Failure(name: "AbortError", message: "The operation was aborted.")

        static func unsupported(_ what: String) -> Failure {
            Failure(name: "NotSupportedError", message: "\(what) is not supported.")
        }

        static func invalid(_ what: String) -> Failure {
            Failure(name: "TypeError", message: what)
        }

        var reply: String { "\(name): \(message)" }
    }

    private struct Session {
        let session: LanguageModelSession
        let options: GenerationOptions
    }

    private let allows: (WKSecurityOrigin) -> Bool
    private var sessions: [String: Session] = [:]
    private var requests: [String: Task<Void, Never>] = [:]
    private var lastSession = 0

    /// `allows`: si un origen es este Paperclip.
    init(allows: @escaping (WKSecurityOrigin) -> Bool) {
        self.allows = allows
    }

    /// Una página nueva no hereda las sesiones de la anterior; lo que estaba escribiendo se corta.
    func reset() {
        requests.values.forEach { $0.cancel() }
        requests = [:]
        sessions = [:]
    }

    func userContentController(
        _ controller: WKUserContentController, didReceive message: WKScriptMessage,
        replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void
    ) {
        guard allows(message.frameInfo.securityOrigin), let body = message.body as? [String: Any],
              let op = body["op"] as? String
        else { return replyHandler(nil, Failure.notAllowed.reply) }

        let request = body["request"] as? String ?? UUID().uuidString
        if op == "cancel" {
            requests.removeValue(forKey: request)?.cancel()
            return replyHandler(nil, nil)
        }
        requests[request] = Task {
            do {
                replyHandler(try await handle(op, body), nil)
            } catch {
                replyHandler(nil, Self.failure(for: error).reply)
            }
            requests[request] = nil
        }
    }

    private func handle(_ op: String, _ body: [String: Any]) async throws -> Any? {
        switch op {
        case "availability":
            return Self.availability(languages: body["languages"] as? [String] ?? [])
        case "create":
            return try create(body)
        case "clone":
            let source = try session(body)
            return store(Session(
                session: LanguageModelSession(model: .default, transcript: source.session.transcript),
                options: source.options
            ))
        case "prompt":
            return try await prompt(body)
        case "destroy":
            if let id = body["session"] as? String { sessions[id] = nil }
            return nil
        default:
            throw Failure.unsupported("“\(op)”")
        }
    }

    private static func availability(languages: [String]) -> String {
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available:
            return languages.allSatisfy { model.supportsLocale(Locale(identifier: $0)) } ? "available" : "unavailable"
        case .unavailable(.modelNotReady):
            return "downloading"
        case .unavailable:
            return "unavailable"
        }
    }

    private func create(_ body: [String: Any]) throws -> String {
        guard Self.availability(languages: body["languages"] as? [String] ?? []) == "available" else {
            throw Failure.unavailable
        }
        let prompts = body["initialPrompts"] as? [[String: Any]] ?? []
        let entries: [Transcript.Entry] = try prompts.enumerated().map { index, prompt in
            guard let role = prompt["role"] as? String, let content = prompt["content"] as? String else {
                throw Failure.invalid("Each initial prompt needs a role and text content.")
            }
            let segments = [Transcript.Segment.text(.init(content: content))]
            switch role {
            case "system" where index == 0:
                return .instructions(.init(segments: segments, toolDefinitions: []))
            case "system":
                throw Failure.invalid("The system prompt must be the first one.")
            case "user":
                return .prompt(.init(segments: segments))
            case "assistant":
                return .response(.init(assetIDs: [], segments: segments))
            default:
                throw Failure.invalid("Unknown role “\(role)”.")
            }
        }
        let topK = (body["topK"] as? NSNumber)?.intValue
        let options = GenerationOptions(
            sampling: topK.map { .random(top: $0) },
            temperature: (body["temperature"] as? NSNumber)?.doubleValue
        )
        return store(Session(
            session: LanguageModelSession(model: .default, transcript: Transcript(entries: entries)),
            options: options
        ))
    }

    private func prompt(_ body: [String: Any]) async throws -> String {
        let entry = try session(body)
        guard let text = body["text"] as? String else { throw Failure.invalid("The prompt must be text.") }
        // Como en Chrome, un prompt espera al anterior: uno al mismo tiempo, o uno cortado que el modelo
        // todavía termina por dentro.
        while entry.session.isResponding {
            try await Task.sleep(for: Self.busyPollInterval)
        }
        guard let constraint = body["schema"], !(constraint is NSNull) else {
            return try await entry.session.respond(to: text, options: entry.options).content
        }
        let schema = try ResponseSchema.generationSchema(from: constraint)
        let response = try await entry.session.respond(
            to: text, schema: schema, includeSchemaInPrompt: false, options: entry.options
        )
        return response.content.jsonString
    }

    private func session(_ body: [String: Any]) throws -> Session {
        guard let id = body["session"] as? String, let session = sessions[id] else { throw Failure.destroyed }
        return session
    }

    private func store(_ session: Session) -> String {
        lastSession += 1
        let id = "s\(lastSession)"
        sessions[id] = session
        return id
    }

    private static func failure(for error: Error) -> Failure {
        if let failure = error as? Failure { return failure }
        if error is CancellationError { return .aborted }
        guard let error = error as? LanguageModelSession.GenerationError else {
            return Failure(name: "UnknownError", message: error.localizedDescription)
        }
        switch error {
        case .exceededContextWindowSize:
            return Failure(name: "QuotaExceededError", message: "The session ran out of room for the answer.")
        case .unsupportedLanguageOrLocale:
            return Failure(name: "NotSupportedError", message: "The model doesn't support this language.")
        case .guardrailViolation, .refusal:
            return Failure(name: "NotAllowedError", message: "The model declined to answer.")
        case .assetsUnavailable:
            return .unavailable
        case .unsupportedGuide:
            return .unsupported("A rule in the response constraint")
        case .rateLimited:
            return Failure(name: "InvalidStateError", message: "The model is busy; try again later.")
        default:
            return Failure(name: "UnknownError", message: error.localizedDescription)
        }
    }

    /// El JSON Schema de `responseConstraint` como esquema de Foundation Models. language-model.js manda las
    /// propiedades de cada objeto como lista (`[{name, schema}]`), en su orden.
    private struct ResponseSchema {
        private var names = 0

        static func generationSchema(from json: Any) throws -> GenerationSchema {
            var converter = ResponseSchema()
            return try GenerationSchema(root: converter.convert(json, name: "Response"), dependencies: [])
        }

        /// Un nombre distinto para cada objeto y cada lista de opciones.
        private mutating func unique(_ base: String) -> String {
            names += 1
            return "\(base)\(names)"
        }

        private mutating func convert(_ json: Any, name: String) throws -> DynamicGenerationSchema {
            guard let node = json as? [String: Any] else { throw Failure.unsupported("A schema that isn't an object") }
            let description = node["description"] as? String
            if let constant = node["const"] {
                return try choices([constant], name: name, description: description)
            }
            if let options = node["enum"] as? [Any] {
                return try choices(options, name: name, description: description)
            }
            if let options = node["anyOf"] as? [Any] {
                let schemas = try options.enumerated().map { index, option in try convert(option, name: "\(name)\(index)") }
                return DynamicGenerationSchema(name: unique(name), description: description, anyOf: schemas)
            }
            switch node["type"] as? String {
            case "object":
                let required = Set(node["required"] as? [String] ?? [])
                let properties = try (node["properties"] as? [[String: Any]] ?? []).map { property in
                    guard let key = property["name"] as? String, let schema = property["schema"] else {
                        throw Failure.unsupported("An object property without a schema")
                    }
                    return DynamicGenerationSchema.Property(
                        name: key, description: (schema as? [String: Any])?["description"] as? String,
                        schema: try convert(schema, name: key), isOptional: !required.contains(key)
                    )
                }
                return DynamicGenerationSchema(name: unique(name), description: description, properties: properties)
            case "array":
                guard let items = node["items"] else { throw Failure.unsupported("An array without items") }
                return DynamicGenerationSchema(
                    arrayOf: try convert(items, name: "\(name)Item"),
                    minimumElements: (node["minItems"] as? NSNumber)?.intValue,
                    maximumElements: (node["maxItems"] as? NSNumber)?.intValue
                )
            case "string":
                return DynamicGenerationSchema(type: String.self)
            case "integer":
                return DynamicGenerationSchema(type: Int.self, guides: Self.integerGuides(node))
            case "number":
                return DynamicGenerationSchema(type: Double.self, guides: Self.numberGuides(node))
            case "boolean":
                return DynamicGenerationSchema(type: Bool.self)
            default:
                throw Failure.unsupported("The schema type “\(node["type"] ?? "none")”")
            }
        }

        private mutating func choices(_ values: [Any], name: String, description: String?) throws -> DynamicGenerationSchema {
            let strings = values.compactMap { $0 as? String }
            guard !strings.isEmpty, strings.count == values.count else { throw Failure.unsupported("An enum that isn't text") }
            return DynamicGenerationSchema(name: unique(name), description: description, anyOf: strings)
        }

        private static func integerGuides(_ node: [String: Any]) -> [GenerationGuide<Int>] {
            let low = (node["minimum"] as? NSNumber).map { Int($0.doubleValue.rounded(.up)) }
            let high = (node["maximum"] as? NSNumber).map { Int($0.doubleValue.rounded(.down)) }
            switch (low, high) {
            case let (low?, high?): return [.range(low...max(low, high))]
            case let (low?, nil): return [.minimum(low)]
            case let (nil, high?): return [.maximum(high)]
            case (nil, nil): return []
            }
        }

        private static func numberGuides(_ node: [String: Any]) -> [GenerationGuide<Double>] {
            let low = (node["minimum"] as? NSNumber)?.doubleValue
            let high = (node["maximum"] as? NSNumber)?.doubleValue
            switch (low, high) {
            case let (low?, high?): return [.range(low...max(low, high))]
            case let (low?, nil): return [.minimum(low)]
            case let (nil, high?): return [.maximum(high)]
            case (nil, nil): return []
            }
        }
    }
}
