import Foundation
import OSLog

/// Una respuesta de Paperclip que la app no esperaba: una ruta que ya no existe (404 o 405), un JSON que no se
/// puede leer, o un campo que falta, viene vacío, cambió de tipo o trae un valor desconocido. La función que la
/// pidió se apaga sola (la app vuelve a lo de antes: «Abrir en Paperclip», o sin el botón nuevo) y aquí queda
/// una línea en el registro con la ruta y lo que no se pudo leer.
enum Unexpected {
    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "PaperclipDispatch", category: "unexpected-response")

    static func note(_ path: String, _ what: String) {
        log.error("\(path, privacy: .public): \(what, privacy: .public)")
    }

    /// Lo que dice un error de lectura de JSON, sin el texto largo de Foundation.
    static func describe(_ error: DecodingError) -> String {
        func at(_ context: DecodingError.Context) -> String {
            let path = context.codingPath.map { $0.intValue.map { "[\($0)]" } ?? $0.stringValue }.joined(separator: ".")
            return path.isEmpty ? "the response" : path
        }
        return switch error {
        case let .keyNotFound(key, context): "missing \(key.stringValue) in \(at(context))"
        case let .valueNotFound(_, context): "null at \(at(context))"
        case let .typeMismatch(type, context): "\(at(context)) isn’t \(type)"
        case let .dataCorrupted(context): "unreadable JSON at \(at(context))"
        @unknown default: "unreadable JSON"
        }
    }
}
