import Foundation
import UserNotifications

/// Avisos de macOS con UNUserNotificationCenter: el clic abre lo que avisó. El permiso no se pide al abrir:
/// lo pide la bienvenida, después de mostrar para qué sirve, o la persona desde Ajustes o el recordatorio.
@MainActor
final class NotificationBridge: NSObject, UNUserNotificationCenterDelegate {
    /// Permiso con los nombres de la API web: "granted", "denied" o "default".
    private(set) var permission = "default"
    private(set) var access: NotificationAccess?
    var onClick: ((_ href: String?) -> Void)?
    var onPermissionChange: ((_ permission: String) -> Void)?
    /// También cuando cambian los banners o el número del Dock en Ajustes del Sistema.
    var onAccessChange: ((NotificationAccess) -> Void)?

    private let center = UNUserNotificationCenter.current()

    func start() {
        center.delegate = self
        refresh()
    }

    func refresh() {
        Task { update(await NotificationAccess.current()) }
    }

    /// Pide el permiso (si nunca se pidió) y avisa cómo quedó. Si macOS rechaza el pedido, abre Ajustes del
    /// Sistema: es lo único que queda, y un botón que no hace nada parece roto.
    func request() async -> NotificationAccess {
        let (access, failed) = await NotificationAccess.request()
        update(access)
        if failed { NotificationAccess.openSystemSettings() }
        return access
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

    private func update(_ access: NotificationAccess) {
        if access != self.access {
            self.access = access
            onAccessChange?(access)
        }
        guard access.webPermission != permission else { return }
        permission = access.webPermission
        onPermissionChange?(permission)
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
