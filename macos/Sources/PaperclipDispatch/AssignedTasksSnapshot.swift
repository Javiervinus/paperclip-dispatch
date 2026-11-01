import SwiftUI

/// Los avisos de una tarea asignada en el ensayo de `snapshot.zsh notifications`: el de la Mac (uno, y el
/// resumen de la primera vez), el mensaje de Telegram y cómo queda al cerrarse o reasignarse. Con los mismos
/// textos que arma el código de verdad (`AssignedTaskFormat`, `TelegramChannel.linkKeyboard`).
extension NotificationsSnapshot {
    static func assignedTaskCases(channel: TelegramChannel) -> [(file: String, view: AnyView)] {
        let notice = AssignedTaskNotice(
            issueId: UUID().uuidString.lowercased(),
            identifier: "ACME-207",
            title: String(localized: "Renew the domain with the company card"),
            excerpt: AssignedTaskFormat.excerpt(
                String(localized: """
                    The domain expires on Friday and the registrar only takes the company card, which I can’t use. \
                    Renew it for two years from the registrar’s dashboard and leave the receipt in this task.
                    """),
                limit: 400
            ),
            assignerName: String(localized: "Operations"),
            projectName: String(localized: "Website"),
            href: "/ACME/issues/ACME-207"
        )
        let mac = AssignedTaskFormat.mac(notice)
        let html = AssignedTaskFormat.telegram(notice)
        let buttons = (channel.linkKeyboard(notice.href)?["inline_keyboard"] as? [[[String: Any]]] ?? [])
            .map { $0.compactMap { $0["text"] as? String } }
        func telegram(_ ending: AssignedTaskEnding?) -> TelegramMessagePreview {
            TelegramMessagePreview(html: ending.map { html + "\n\n" + AssignedTaskFormat.ending($0) } ?? html, buttons: buttons)
        }
        return [
            ("mac-task", AnyView(MacScene(notices: [MacNoticePreview(title: mac.title, body: mac.body, action: nil)]))),
            ("mac-tasks-summary", AnyView(MacScene(notices: [
                MacNoticePreview(title: "Acme", body: AssignedTaskFormat.summary(5), action: nil),
            ]))),
            ("telegram-task", AnyView(TelegramScene(messages: [telegram(nil)]))),
            ("telegram-task-done", AnyView(TelegramScene(messages: [telegram(.done)]))),
            ("telegram-task-reassigned", AnyView(TelegramScene(messages: [
                telegram(.reassignedToAgent(String(localized: "Chief of Staff"))),
            ]))),
        ]
    }
}
