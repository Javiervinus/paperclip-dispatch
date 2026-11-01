import Foundation
import WebKit

/// La API de Paperclip con la sesión iniciada en la página (las cookies de WebKit), la misma que usa la
/// web. Lo que se hace por aquí queda a nombre del usuario, como si lo hubiera hecho en la página.
@MainActor
final class PaperclipAPI {
    enum APIError: LocalizedError {
        case signedOut
        case http(Int, String?)

        var errorDescription: String? {
            switch self {
            case .signedOut:
                "La app no tiene la sesión de Paperclip: ábrela e inicia sesión."
            case .http(404, _):
                "Ya no existe en Paperclip."
            case let .http(409, message), let .http(422, message):
                "Paperclip no lo aceptó\(message.map { " (\($0))" } ?? ""). Puede que ya estuviera resuelta."
            case let .http(status, message):
                "Paperclip respondió \(status)\(message.map { ": \($0)" } ?? "")."
            }
        }
    }

    let serverURL: URL
    private let session: URLSession

    init(serverURL: URL) {
        self.serverURL = serverURL
        // La sesión va a mano en cada pedido, con las cookies de la página.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        session = URLSession(configuration: configuration)
    }

    func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        try JSONDecoder().decode(T.self, from: await send("GET", path, query: query, body: nil))
    }

    /// Un cambio (aceptar, responder, comentar). Lo que devuelve Paperclip no hace falta.
    func post(_ path: String, _ body: [String: Any] = [:]) async throws {
        _ = try await send("POST", path, query: [], body: JSONSerialization.data(withJSONObject: body))
    }

    /// Un cambio cuya respuesta sí hace falta (p. ej. si Paperclip aceptó o saltó un despertar).
    func post<T: Decodable>(_ path: String, _ body: [String: Any] = [:], returning: T.Type) async throws -> T {
        let data = try await send("POST", path, query: [], body: JSONSerialization.data(withJSONObject: body))
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func send(_ method: String, _ path: String, query: [URLQueryItem], body: Data?) async throws -> Data {
        var url = serverURL.appending(path: path)
        if !query.isEmpty { url.append(queryItems: query) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            // Paperclip rechaza los cambios con sesión de navegador que no vienen de su propio origen (CSRF).
            request.setValue(origin, forHTTPHeaderField: "Origin")
        }
        let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
        let host = url.host() ?? ""
        let matching = cookies.filter { cookie in
            let domain = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
            return host == domain || host.hasSuffix("." + domain)
        }
        for (field, value) in HTTPCookie.requestHeaderFields(with: matching) {
            request.setValue(value, forHTTPHeaderField: field)
        }
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 { throw APIError.signedOut }
        guard (200..<300).contains(status) else {
            let message = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error
            throw APIError.http(status, message)
        }
        return data
    }

    private var origin: String {
        var origin = "\(serverURL.scheme ?? "https")://\(serverURL.host() ?? "")"
        if let port = serverURL.port { origin += ":\(port)" }
        return origin
    }

    private struct ErrorBody: Decodable {
        let error: String?
    }
}
