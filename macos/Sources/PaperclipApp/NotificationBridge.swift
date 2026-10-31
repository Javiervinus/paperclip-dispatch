import Foundation
import UserNotifications

/// Avisos de macOS con UNUserNotificationCenter: el permiso se pide como corresponde la primera vez,
/// y el clic abre lo que avisó.
@MainActor
final class NotificationBridge: NSObject, UNUserNotificationCenterDelegate {
    /// Permiso con los nombres de la API web: "granted", "denied" o "default".
    private(set) var permission = "default"
    var onClick: ((_ href: String?) -> Void)?
    var onPermissionChange: ((_ permission: String) -> Void)?

    private let center = UNUserNotificationCenter.current()

    func start() {
        center.delegate = self
        Task { await updatePermission(requestIfNeeded: true) }
    }

    func refresh() {
        Task { await updatePermission(requestIfNeeded: false) }
    }

    /// `tag` reemplaza el aviso anterior con la misma etiqueta.
    func show(id: String, tag: String?, title: String, body: String, href: String?) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = ["id": id, "href": href ?? ""]
        let identifier = tag.flatMap { $0.isEmpty ? nil : $0 } ?? id
        center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
    }

    private func updatePermission(requestIfNeeded: Bool) async {
        if requestIfNeeded, await center.notificationSettings().authorizationStatus == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
        }
        let value = switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral: "granted"
        case .denied: "denied"
        default: "default"
        }
        guard value != permission else { return }
        permission = value
        onPermissionChange?(value)
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let href = (response.notification.request.content.userInfo["href"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        await MainActor.run { onClick?(href) }
    }

    // Con la app al frente también se muestran: DecisionsMonitor ya decide si avisar con la ventana a la vista.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}
