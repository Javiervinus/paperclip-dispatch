import Foundation

/// Lo que build.sh deja en el Info.plist. Nada de esto se escribe en el código.
struct AppConfig: Sendable {
    /// Dirección de Paperclip por Tailscale (`tailscale serve`).
    let serverURL: URL
    /// El update.sh de Paperclip, que actualiza sin caer en el bug #13697. Sin él no hay botón «Actualizar».
    let updateScript: URL?

    static func load(from bundle: Bundle = .main) -> AppConfig? {
        guard let raw = bundle.object(forInfoDictionaryKey: "PaperclipServerURL") as? String,
              let serverURL = URL(string: raw), serverURL.host() != nil
        else { return nil }
        let updateScript = (bundle.object(forInfoDictionaryKey: "PaperclipUpdateScript") as? String)
            .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
        return AppConfig(serverURL: serverURL, updateScript: updateScript)
    }

    /// Nombre de la app, para los menús.
    static var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? ProcessInfo.processInfo.processName
    }

    /// Si una dirección es de este Paperclip (mismo esquema, servidor y puerto).
    func isInternal(_ url: URL) -> Bool {
        url.scheme == serverURL.scheme && url.host() == serverURL.host() && url.port == serverURL.port
    }
}
