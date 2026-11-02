import Foundation
import WebKit

/// La API web de avisos de la página (`Notification`, notifications.js) con avisos de macOS, para los plugins
/// de Paperclip que avisan con ella. Como en un navegador, la página pide el permiso desde un clic y hasta
/// entonces no avisa; así lo que avisa la app (las decisiones, las tareas) no llega repetido sin que nadie lo
/// pida. Queda en Ajustes → Avisos (`Preferences.pageNotifications`), y solo le contesta a este Paperclip.
@MainActor
final class PageNotifications: NSObject, WKScriptMessageHandlerWithReply {
    static let handlerName = "paperclipDispatchNotifications"
    /// Los avisos de la página van con este prefijo, para no pisar los de la app.
    private static let prefix = "page:"

    private let notifications: NotificationBridge
    private let preferences: Preferences
    private let allows: (WKSecurityOrigin) -> Bool

    /// `allows`: si un origen es este Paperclip.
    init(notifications: NotificationBridge, preferences: Preferences, allows: @escaping (WKSecurityOrigin) -> Bool) {
        self.notifications = notifications
        self.preferences = preferences
        self.allows = allows
    }

    /// El permiso como lo ve la página: "denied" si macOS no deja avisar a la app; "granted" si además se
    /// permitió en la página; si no, "default".
    var permission: String {
        switch notifications.access?.permission {
        case .denied: "denied"
        case .granted: preferences.pageNotifications ? "granted" : "default"
        case .notDetermined, nil: "default"
        }
    }

    /// El identificador del aviso de macOS de un aviso de la página: su `tag` si tiene, para reemplazar al
    /// anterior con la misma.
    static func identifier(id: String, tag: String?) -> String {
        guard let tag, !tag.isEmpty else { return prefix + id }
        return prefix + "tag:" + tag
    }

    func userContentController(
        _ controller: WKUserContentController, didReceive message: WKScriptMessage,
        replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void
    ) {
        guard allows(message.frameInfo.securityOrigin), let body = message.body as? [String: Any],
              let op = body["op"] as? String
        else { return replyHandler(nil, "Only Paperclip can show notifications.") }

        switch op {
        case "request":
            Task { replyHandler(await request(), nil) }
        case "show":
            guard permission == "granted", let id = body["id"] as? String else {
                return replyHandler(nil, "Notifications aren't allowed.")
            }
            let tag = body["tag"] as? String
            notifications.show(
                id: Self.identifier(id: id, tag: tag), tag: nil, title: body["title"] as? String ?? "",
                body: body["body"] as? String ?? "", href: nil, pageNotification: id,
                sound: body["silent"] as? Bool != true
            )
            replyHandler(nil, nil)
        case "close":
            if let id = body["id"] as? String {
                notifications.remove(identifier: Self.identifier(id: id, tag: body["tag"] as? String))
            }
            replyHandler(nil, nil)
        default:
            replyHandler(nil, "Unknown operation.")
        }
    }

    /// Lo pide macOS si nunca se pidió; con su permiso, la página queda permitida.
    private func request() async -> String {
        var access = notifications.access
        if access == nil || access?.permission == .notDetermined {
            access = await notifications.request()
        }
        if access?.permission == .granted { preferences.pageNotifications = true }
        return permission
    }
}
