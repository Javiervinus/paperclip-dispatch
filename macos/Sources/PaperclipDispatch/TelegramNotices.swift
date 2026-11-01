import Foundation

/// Los avisos del bot que no son decisiones (las tareas asignadas, de `AssignedTasksMonitor`): mensajes con
/// «Abrir en Paperclip» y sin otros botones, que se editan cuando cambia lo que avisaron. Usan el mismo chat
/// vinculado y, como las decisiones, no salen con el bot apagado en Ajustes.
extension TelegramChannel {
    /// El chat vinculado, si el bot está encendido; si no, no se manda nada.
    var noticeChatId: Int64? { state.enabled && bot != nil ? state.chatId : nil }

    /// Un aviso con «Abrir en Paperclip» (si el teléfono puede abrirlo). Devuelve su mensaje, o `nil` si no salió.
    func postNotice(_ html: String, href: String?) async -> Int? {
        guard let bot, let chatId = noticeChatId else { return nil }
        var params: [String: Any] = [
            "chat_id": chatId, "text": html, "parse_mode": "HTML", "link_preview_options": ["is_disabled": true],
        ]
        params["reply_markup"] = linkKeyboard(href)
        do {
            let message: TelegramBotAPI.MessageReference = try await bot.call("sendMessage", params)
            return message.messageId
        } catch let failure as TelegramBotAPI.Failure where failure.reason.contains("BUTTON_URL_INVALID") {
            // Telegram no acepta esa dirección: va sin el enlace.
            params["reply_markup"] = nil
            let message: TelegramBotAPI.MessageReference? = try? await bot.call("sendMessage", params)
            return message?.messageId
        } catch {
            return nil
        }
    }

    /// Cambia el texto de un aviso y le deja «Abrir en Paperclip». `false` si no se pudo (sin conexión con
    /// Telegram); si el mensaje ya no está o ya decía eso, no hay nada más que hacer y da `true`.
    @discardableResult
    func editNotice(_ messageId: Int, html: String, href: String?) async -> Bool {
        guard let bot, let chatId = noticeChatId else { return false }
        var params: [String: Any] = [
            "chat_id": chatId, "message_id": messageId, "text": html, "parse_mode": "HTML",
            "link_preview_options": ["is_disabled": true],
        ]
        params["reply_markup"] = linkKeyboard(href)
        do {
            try await bot.send("editMessageText", params)
            return true
        } catch let failure as TelegramBotAPI.Failure where failure.reason.contains("BUTTON_URL_INVALID") {
            params["reply_markup"] = nil
            return (try? await bot.send("editMessageText", params)) != nil
        } catch let failure as TelegramBotAPI.Failure where failure.code != 429 {
            // Telegram contestó que no (el mensaje se borró, ya decía eso): reintentar no cambia nada.
            return true
        } catch {
            return false
        }
    }

    /// Un texto simple en respuesta a un mensaje (p. ej. la confirmación de un comentario).
    func replyNotice(_ text: String, to messageId: Int) async {
        guard let bot, let chatId = noticeChatId else { return }
        try? await bot.send("sendMessage", [
            "chat_id": chatId,
            "text": text,
            "reply_parameters": ["message_id": messageId, "allow_sending_without_reply": true],
        ])
    }

    /// El botón «Abrir en Paperclip», o `nil` si el teléfono no puede abrir la dirección (una local).
    func linkKeyboard(_ href: String?) -> [String: Any]? {
        guard let url = paperclipURL(href) else { return nil }
        return ["inline_keyboard": [[["text": String(localized: "Open in Paperclip"), "url": url.absoluteString]]]]
    }
}
