import AppKit
import OSLog
import UserNotifications

/// Avisos de macOS con UNUserNotificationCenter: el clic abre lo que avisó. El permiso no se pide al abrir:
/// lo pide la bienvenida, después de mostrar para qué sirve, o la persona desde Ajustes o el recordatorio.
@MainActor
final class NotificationBridge: NSObject, UNUserNotificationCenterDelegate {
    /// Permiso con los nombres de la API web: "granted", "denied" o "default".
    private(set) var permission = "default"
    private(set) var access: NotificationAccess?
    var onClick: ((_ href: String?) -> Void)?
    /// Un clic en un aviso de la página (PageNotifications), con el `id` que le dio la página.
    var onPageClick: ((_ id: String) -> Void)?
    /// Un clic en el aviso de una versión nueva (`UpdateNotices`): abre ese panel.
    var onUpdatesClick: ((UpdateNotices.Panel) -> Void)?
    /// Se apretó «Despertar a …» en el aviso de una tarea trabada. `id` es el del aviso, para reemplazarlo
    /// con lo que respondió Paperclip; `preview`, su «Ver en vivo», para que el aviso nuevo lo conserve.
    var onWake: ((_ id: String, _ wake: WakeButton, _ href: String?, _ preview: URL?) -> Void)?
    var onPermissionChange: ((_ permission: String) -> Void)?
    /// También cuando cambian los banners o el número del Dock en Ajustes del Sistema.
    var onAccessChange: ((NotificationAccess) -> Void)?

    private let center = UNUserNotificationCenter.current()
    /// Una categoría por cada juego de botones («Despertar a Operaciones», «Ver en vivo»…): macOS fija el
    /// texto de los botones en la categoría. `nil` hasta leer las que ya había, para no quitarles los botones a
    /// avisos anteriores.
    private var categories: [String: UNNotificationCategory]?
    private var registrations: [String: Task<Void, Never>] = [:]
    private nonisolated static let wakeActionId = "wake-agent"
    private nonisolated static let previewActionId = "open-preview"
    private nonisolated static let linkActionId = "open-link"
    private static let wakeCategoryPrefix = "wake-agent:"
    private static let categoryPrefix = "actions:"
    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "PaperclipDispatch", category: "notifications")

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

    /// `tag` reemplaza el aviso anterior con la misma etiqueta; sin ella, el aviso se identifica con `id`. Los
    /// botones, en este orden: con `wake`, el que despierta al agente; con `preview`, «Ver en vivo», que abre esa
    /// dirección; con `openLabel`, uno con ese texto que abre `href` (lo mismo que un clic en el aviso). Sin
    /// `sound`, llega callado (p. ej. la respuesta a «Despertar»). Con `pageNotification`, es un aviso de la
    /// página: el clic va a `onPageClick` con ese id. Con `opensPanel`, el clic abre ese panel (el de
    /// actualizaciones o el de plugins, `onUpdatesClick`).
    func show(id: String, tag: String?, title: String, body: String, href: String?, wake: WakeButton? = nil,
              preview: URL? = nil, openLabel: String? = nil, pageNotification: String? = nil,
              opensPanel: UpdateNotices.Panel? = nil, sound: Bool = true) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if sound { content.sound = .default }
        var info: [String: Any] = ["href": href ?? ""]
        if let wake { info.merge(wake.userInfo) { _, new in new } }
        if let preview { info["previewURL"] = preview.absoluteString }
        if let pageNotification { info["pageNotification"] = pageNotification }
        if let opensPanel { info["opensPanel"] = opensPanel.rawValue }
        content.userInfo = info
        let identifier = tag.flatMap { $0.isEmpty ? nil : $0 } ?? id
        var buttons: [Button] = []
        if let wake { buttons.append(Button(id: Self.wakeActionId, title: wake.title)) }
        if preview != nil { buttons.append(Button(id: Self.previewActionId, title: String(localized: "Open preview"))) }
        if let openLabel { buttons.append(Button(id: Self.linkActionId, title: openLabel)) }
        Self.log.notice("\(identifier, privacy: .public): buttons [\(buttons.map(\.id).joined(separator: ", "), privacy: .public)]")
        guard !buttons.isEmpty else {
            center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
            return
        }
        Task {
            content.categoryIdentifier = await category(buttons)
            try? await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
        }
    }

    /// Quita un aviso de la lista de macOS (y de la pantalla, si sigue ahí).
    func remove(identifier: String) {
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
    }

    private struct Button {
        let id: String
        let title: String
    }

    /// Registra (una vez) la categoría con esos botones y devuelve su identificador, cuando macOS ya la tiene:
    /// si no, el aviso puede salir sin ellos. Ninguno trae la app al frente: el despertar se hace en segundo
    /// plano, «Ver en vivo» abre el navegador y el enlace a Paperclip muestra la ventana por su cuenta.
    private func category(_ buttons: [Button]) async -> String {
        // Solo «Despertar»: el identificador de siempre, que ya tienen los avisos anteriores.
        let identifier = buttons.count == 1 && buttons[0].id == Self.wakeActionId
            ? Self.wakeCategoryPrefix + buttons[0].title
            : Self.categoryPrefix + buttons.map { "\($0.id)=\($0.title)" }.joined(separator: "|")
        // Dos avisos con los mismos botones a la vez esperan el mismo registro.
        if let registration = registrations[identifier] {
            await registration.value
            return identifier
        }
        let registration = Task { await register(identifier, buttons: buttons) }
        registrations[identifier] = registration
        await registration.value
        return identifier
    }

    private func register(_ identifier: String, buttons: [Button]) async {
        if categories == nil {
            let existing = await center.notificationCategories()
            if categories == nil {
                categories = Dictionary(existing.map { ($0.identifier, $0) }, uniquingKeysWith: { first, _ in first })
            }
        }
        // Sin esperas entre agregarla y registrar todas: dos juegos de botones distintos a la vez no se pisan.
        let actions = buttons.map { UNNotificationAction(identifier: $0.id, title: $0.title, options: []) }
        categories?[identifier] = UNNotificationCategory(identifier: identifier, actions: actions, intentIdentifiers: [])
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
        let preview = LivePreview.url(info["previewURL"] as? String)
        switch response.actionIdentifier {
        case Self.wakeActionId:
            // Solo con el botón; un clic en el aviso lo abre, como siempre.
            guard let wake = WakeButton(userInfo: info) else { return }
            let id = response.notification.request.identifier
            await MainActor.run { onWake?(id, wake, href, preview) }
        case Self.previewActionId:
            // En el navegador: es la página que se está revisando, no Paperclip.
            guard let preview else { return }
            await MainActor.run { _ = NSWorkspace.shared.open(preview) }
        default:
            if let page = info["pageNotification"] as? String {
                await MainActor.run { onPageClick?(page) }
            } else if let raw = info["opensPanel"] as? String, let panel = UpdateNotices.Panel(rawValue: raw) {
                await MainActor.run { onUpdatesClick?(panel) }
            } else {
                await MainActor.run { onClick?(href) }
            }
        }
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
