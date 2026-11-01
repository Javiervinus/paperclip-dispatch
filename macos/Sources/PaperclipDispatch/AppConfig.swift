import Foundation

/// A qué Paperclip se conecta la app. La dirección la elige cada uno en la bienvenida (o en Ajustes →
/// Paperclip → Cambiar…) y queda en UserDefaults; nada de esto se escribe en el código.
struct AppConfig: Sendable {
    private static let serverURLKey = "serverURL"

    let serverURL: URL
    /// Un script propio para actualizar Paperclip (build.sh lo deja en el Info.plist si se pide con
    /// PAPERCLIP_UPDATE_SCRIPT). Sin él, se actualiza con el comando oficial de su CLI.
    let updateScript: URL?

    init(serverURL: URL, bundle: Bundle = .main) {
        self.serverURL = serverURL
        updateScript = (bundle.object(forInfoDictionaryKey: "PaperclipUpdateScript") as? String)
            .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
    }

    /// La dirección guardada. Un build puede traer una de fábrica (PAPERCLIP_SERVER_URL en build.sh): se
    /// adopta la primera vez como si se hubiera elegido.
    static func load(defaults: UserDefaults = .standard, bundle: Bundle = .main) -> AppConfig? {
        if let saved = defaults.string(forKey: serverURLKey).flatMap(PaperclipLocator.serverURL) {
            return AppConfig(serverURL: saved, bundle: bundle)
        }
        guard let built = (bundle.object(forInfoDictionaryKey: "PaperclipServerURL") as? String)
            .flatMap(PaperclipLocator.serverURL)
        else { return nil }
        save(serverURL: built, defaults: defaults)
        return AppConfig(serverURL: built, bundle: bundle)
    }

    static func save(serverURL: URL, defaults: UserDefaults = .standard) {
        defaults.set(serverURL.absoluteString, forKey: serverURLKey)
    }

    /// Nombre de la app, para los menús y la bienvenida.
    static var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? ProcessInfo.processInfo.processName
    }

    /// Si una dirección es de este Paperclip (mismo esquema, servidor y puerto).
    func isInternal(_ url: URL) -> Bool {
        url.scheme == serverURL.scheme && url.host() == serverURL.host() && url.port == serverURL.port
    }
}
