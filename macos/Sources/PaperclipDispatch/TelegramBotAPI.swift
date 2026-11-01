import Foundation

/// Lo justo de la Bot API de Telegram (https://core.telegram.org/bots/api) para el bot de Decisions.
@MainActor
struct TelegramBotAPI {
    let token: String

    struct Failure: LocalizedError {
        let code: Int?
        let reason: String

        var errorDescription: String? { reason }
    }

    /// Para los pedidos normales; `getUpdates` pasa el suyo.
    private static let defaultTimeout: TimeInterval = 20
    /// Si Telegram pide esperar más que esto (429), el pedido falla en vez de quedarse esperando.
    private static let maxRetryAfter = 30
    private static let session = URLSession(configuration: .ephemeral)
    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    /// `timeout` tiene que pasar el de `getUpdates`, que espera mensajes con la conexión abierta.
    func call<T: Decodable>(
        _ method: String,
        _ params: [String: Any] = [:],
        timeout: TimeInterval = defaultTimeout
    ) async throws -> T {
        guard let url = URL(string: "https://api.telegram.org/bot\(token)/\(method)") else {
            throw Failure(code: nil, reason: "El token tiene caracteres que no van.")
        }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: params)

        let (data, _) = try await Self.session.data(for: request)
        let envelope = try Self.decoder.decode(Envelope<T>.self, from: data)
        if envelope.ok, let result = envelope.result { return result }
        // Demasiados mensajes seguidos: Telegram dice cuánto esperar.
        if envelope.errorCode == 429, let wait = envelope.parameters?.retryAfter, wait <= Self.maxRetryAfter {
            try await Task.sleep(for: .seconds(wait))
            return try await call(method, params, timeout: timeout)
        }
        throw Failure(code: envelope.errorCode, reason: envelope.description ?? "Telegram no respondió bien.")
    }

    /// Para los métodos cuya respuesta no hace falta.
    func send(_ method: String, _ params: [String: Any] = [:]) async throws {
        let _: PresentValue = try await call(method, params)
    }

    private struct Envelope<Result: Decodable>: Decodable {
        let ok: Bool
        let result: Result?
        let description: String?
        let errorCode: Int?
        let parameters: Parameters?
    }

    private struct Parameters: Decodable {
        let retryAfter: Int?
    }
}

// MARK: - Lo que se lee de Telegram

extension TelegramBotAPI {
    struct User: Decodable {
        let id: Int64
        let firstName: String
        let username: String?
    }

    struct Chat: Decodable {
        let id: Int64
        let type: String
    }

    struct Message: Decodable {
        let messageId: Int
        let chat: Chat
        let from: User?
        let text: String?
        let replyToMessage: MessageReference?
    }

    struct MessageReference: Decodable {
        let messageId: Int
    }

    struct CallbackQuery: Decodable {
        let id: String
        let from: User
        let data: String?
    }

    struct Update: Decodable {
        let updateId: Int
        let message: Message?
        let callbackQuery: CallbackQuery?
    }
}
