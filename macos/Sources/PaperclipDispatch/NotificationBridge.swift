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
    /// Se apretó «Despertar a …» en el aviso de una tarea trabada. `id` es el del aviso, para reemplazarlo
    /// con lo que respondió Paperclip.
    var onWake: ((_ id: String, _ wake: WakeButton, _ href: String?) -> Void)?
    var onPermissionChange: ((_ permission: String) -> Void)?
    /// También cuando cambian los banners o el número del Dock en Ajustes del Sistema.
    var onAccessChange: ((NotificationAccess) -> Void)?

    private let center = UNUserNotificationCenter.current()
    /// Una categoría por cada texto de botón («Despertar a Operaciones»): macOS fija el texto de los botones
    /// en la categoría. `nil` hasta leer las que ya había, para no quitarles el botón a avisos anteriores.
    private var categories: [String: UNNotificationCategory]?
    private var registrations: [String: Task<Void, Never>] = [:]
    private nonisolated static let wakeActionId = "wake-agent"
    private static let wakeCategoryPrefix = "wake-agent:"

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

    /// `tag` reemplaza el aviso anterior con la misma etiqueta; sin ella, el aviso se identifica con `id`. Con
    /// `wake`, el aviso lleva el botón para despertar al agente; sin `sound`, llega callado (p. ej. la respuesta
    /// a ese botón).
    func show(id: String, tag: String?, title: String, body: String, href: String?, wake: WakeButton? = nil,
              sound: Bool = true) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if sound { content.sound = .default }
        var info: [String: Any] = ["href": href ?? ""]
        if let wake { info.merge(wake.userInfo) { _, new in new } }
        content.userInfo = info
        let identifier = tag.flatMap { $0.isEmpty ? nil : $0 } ?? id
        guard let wake else {
            center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
            return
        }
        Task {
            content.categoryIdentifier = await wakeCategory(title: wake.title)
            try? await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
        }
    }

    /// Registra (una vez) la categoría con ese texto de botón y devuelve su identificador, cuando macOS ya la
    /// tiene: si no, el aviso puede salir sin el botón. El botón no abre la app ni le da el foco: el despertar
    /// se hace en segundo plano.
    private func wakeCategory(title: String) async -> String {
        let identifier = Self.wakeCategoryPrefix + title
        // Dos avisos con el mismo botón a la vez esperan el mismo registro.
        if let registration = registrations[identifier] {
            await registration.value
            return identifier
        }
        let registration = Task { await register(identifier, title: title) }
        registrations[identifier] = registration
        await registration.value
        return identifier
    }

    private func register(_ identifier: String, title: String) async {
        if categories == nil {
            let existing = await center.notificationCategories()
            if categories == nil {
                categories = Dictionary(existing.map { ($0.identifier, $0) }, uniquingKeysWith: { first, _ in first })
            }
        }
        // Sin esperas entre agregarla y registrar todas: dos botones distintos a la vez no se pisan.
        let action = UNNotificationAction(identifier: Self.wakeActionId, title: title, options: [])
        categories?[identifier] = UNNotificationCategory(identifier: identifier, actions: [action], intentIdentifiers: [])
        center.setNotificationCategories(Set(categories?.values.map { $0 } ?? []))
        _ = await center.notificationCategories()
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
        let info = response.notification.request.content.userInfo
        let href = (info["href"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        if response.actionIdentifier == Self.wakeActionId {
            // Solo con el botón; un clic en el aviso lo abre, como siempre.
            guard let wake = WakeButton(userInfo: info) else { return }
            let id = response.notification.request.identifier
            await MainActor.run { onWake?(id, wake, href) }
            return
        }
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

/// El botón «Despertar a …» de un aviso: viaja en el aviso, para saber a quién despertar al apretarlo.
struct WakeButton: Sendable {
    let target: WakeTarget
    let agentName: String?

    var title: String { WakeText.button(agentName) }

    var userInfo: [String: Any] {
        var info: [String: Any] = ["wakeAgentId": target.agentId, "wakeIssueId": target.issueId]
        if let identifier = target.issueIdentifier { info["wakeIssueIdentifier"] = identifier }
        if let agentName { info["wakeAgentName"] = agentName }
        return info
    }

    init(target: WakeTarget, agentName: String?) {
        self.target = target
        self.agentName = agentName
    }

    init?(userInfo: [AnyHashable: Any]) {
        guard let agentId = userInfo["wakeAgentId"] as? String, let issueId = userInfo["wakeIssueId"] as? String
        else { return nil }
        target = WakeTarget(agentId: agentId, issueId: issueId, issueIdentifier: userInfo["wakeIssueIdentifier"] as? String)
        agentName = userInfo["wakeAgentName"] as? String
    }
}
