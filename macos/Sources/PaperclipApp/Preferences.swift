import AppKit
import Observation

/// Lo que se elige en la ventana Ajustes (Cmd+,). Se guarda en UserDefaults.
@MainActor
@Observable
final class Preferences {
    enum Appearance: String, CaseIterable, Identifiable {
        case system, light, dark

        var id: Self { self }

        var title: String {
            switch self {
            case .system: "Sistema"
            case .light: "Claro"
            case .dark: "Oscuro"
            }
        }

        /// `nil` sigue a la Mac, también cuando cambia sola por horario.
        var nsAppearance: NSAppearance? {
            switch self {
            case .system: nil
            case .light: NSAppearance(named: .aqua)
            case .dark: NSAppearance(named: .darkAqua)
            }
        }
    }

    private enum Key {
        static let appearance = "appearance"
        static let decisionNotifications = "decisionNotifications"
        static let notifyWhileLooking = "notifyWhileLooking"
        static let dockBadge = "dockBadge"
        static let liquidGlassPage = "liquidGlassPage"
    }

    var appearance: Appearance {
        didSet { save(appearance.rawValue, Key.appearance) }
    }

    /// Un aviso de macOS por cada decisión nueva.
    var decisionNotifications: Bool {
        didSet { save(decisionNotifications, Key.decisionNotifications) }
    }

    /// Avisar también con la ventana de Paperclip al frente, donde la barra lateral ya lo muestra.
    var notifyWhileLooking: Bool {
        didSet { save(notifyWhileLooking, Key.notifyWhileLooking) }
    }

    /// El número de pendientes en el ícono del Dock.
    var dockBadge: Bool {
        didSet { save(dockBadge, Key.dockBadge) }
    }

    /// Experimental: la barra lateral de Paperclip sobre Liquid Glass (glass.css). Sin esto, la barra lateral
    /// conserva su fondo. Apagado por defecto: le quita estilos a Paperclip y una versión nueva lo puede romper.
    var liquidGlassPage: Bool {
        didSet { save(liquidGlassPage, Key.liquidGlassPage) }
    }

    /// La app aplica los cambios aquí (tema, número del Dock, vidrio).
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.appearance: Appearance.system.rawValue,
            Key.decisionNotifications: true,
            Key.notifyWhileLooking: false,
            Key.dockBadge: true,
            Key.liquidGlassPage: false,
        ])
        appearance = defaults.string(forKey: Key.appearance).flatMap(Appearance.init) ?? .system
        decisionNotifications = defaults.bool(forKey: Key.decisionNotifications)
        notifyWhileLooking = defaults.bool(forKey: Key.notifyWhileLooking)
        dockBadge = defaults.bool(forKey: Key.dockBadge)
        liquidGlassPage = defaults.bool(forKey: Key.liquidGlassPage)
    }

    private func save(_ value: Any, _ key: String) {
        defaults.set(value, forKey: key)
        onChange?()
    }
}

/// Lo que la ventana Ajustes muestra y la app va sabiendo: versión de Paperclip y permiso de avisos.
@MainActor
@Observable
final class AppStatus {
    var paperclipVersion: String?
    /// La versión nueva, si hay.
    var latestVersion: String?
    var checkingUpdate = false
    var updateCheckFailed = false
    /// Por qué falló la última revisión, para mostrarlo en Ajustes.
    var updateCheckError: String?
    var lastCheckedAt: Date?
    /// El paso de la actualización mientras corre.
    var updateProgress: String?
    /// Por qué no se revisan versiones desde aquí (Paperclip en otra computadora, falta su CLI).
    var updatesUnavailable: String?
    /// Con los nombres de la API web: "granted", "denied" o "default".
    var notificationPermission = "default"
    /// El permiso y si macOS deja los banners y el número del Dock. `nil` hasta que se sabe.
    var notificationAccess: NotificationAccess?
    /// El aviso de permiso de macOS, pedido desde Ajustes, espera la respuesta.
    var requestingNotifications = false
}
