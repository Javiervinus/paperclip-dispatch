import AppKit
import UserNotifications

/// Lo que macOS deja hacer con los avisos de la app: el permiso y, si está dado, si salen como banner y con
/// el número en el Dock. Se puede dar el permiso y apagar esas dos cosas en Ajustes del Sistema.
struct NotificationAccess: Equatable {
    enum Permission: Equatable {
        case notDetermined, denied, granted
    }

    let permission: Permission
    /// Aparecen en pantalla (banner o alerta) y no solo en el Centro de notificaciones.
    let banners: Bool
    /// macOS deja poner el número en el ícono del Dock.
    let badge: Bool

    /// Todo lo que la app usa: el permiso, los banners y el número.
    var isComplete: Bool { permission == .granted && banners && badge }

    /// Con los nombres de la API web de avisos, que usa Ajustes.
    var webPermission: String {
        switch permission {
        case .granted: "granted"
        case .denied: "denied"
        case .notDetermined: "default"
        }
    }

    static func current() async -> NotificationAccess {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        let permission: Permission = switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: .granted
        case .denied: .denied
        default: .notDetermined
        }
        return NotificationAccess(
            permission: permission,
            banners: settings.alertSetting == .enabled && settings.alertStyle != .none,
            badge: settings.badgeSetting == .enabled
        )
    }

    /// Pide el permiso si nunca se pidió (macOS muestra su aviso) y devuelve cómo quedó. Si ya se negó, macOS
    /// no vuelve a preguntar: queda Ajustes del Sistema (`openSystemSettings()`). `failed`: macOS rechazó el
    /// pedido sin preguntar (le pasa, por ejemplo, a una copia que corre desde una carpeta temporal).
    static func request() async -> (access: NotificationAccess, failed: Bool) {
        let center = UNUserNotificationCenter.current()
        var failed = false
        if await center.notificationSettings().authorizationStatus == .notDetermined {
            do {
                _ = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            } catch {
                failed = true
            }
        }
        return (await current(), failed)
    }

    /// Ajustes del Sistema → Notificaciones, en la página de esta app.
    @MainActor
    static func openSystemSettings() {
        let id = Bundle.main.bundleIdentifier ?? ""
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)") {
            NSWorkspace.shared.open(url)
        }
    }
}
