import Foundation

/// Los avisos del bot que no son decisiones (las tareas asignadas, de `AssignedTasksMonitor`, y los topes
/// diarios, de `RunLimitMonitor`): mensajes con un enlace a Paperclip (y «Ver en vivo», si la tarea tiene algo
/// servido) y sin otros botones, que se editan cuando cambia lo que avisaron. Usan el mismo chat vinculado y,
/// como las decisiones, no salen con el bot apagado en Ajustes.
extension TelegramChannel {
    /// El chat vinculado, si el bot está encendido; si no, no se manda nada.
    var noticeChatId: Int64? { state.enabled && bot != nil ? state.chatId : nil }

    /// Un aviso con «Abrir en Paperclip» (o `linkLabel`) y «Ver en vivo», si el teléfono puede abrirlos.
    /// Devuelve su mensaje, o `nil` si no salió.
    func postNotice(_ html: String, href: String?, preview: URL? = nil, linkLabel: String? = nil) async -> Int? {
        guard let bot, let chatId = noticeChatId else { return nil }
        func params(_ links: Links) -> [String: Any] {
            var params: [String: Any] = [
                "chat_id": chatId, "text": html, "parse_mode": "HTML", "link_preview_options": ["is_disabled": true],
            ]
            params["reply_markup"] = noticeKeyboard(href, preview: preview, label: linkLabel, links: links)
            return params
        }
        // Si Telegram no acepta una dirección, va sin ella.
        let message: TelegramBotAPI.MessageReference? = try? await withLinkFallback(preview: preview != nil) { links in
            try await bot.call("sendMessage", params(links))
        }
        return message?.messageId
    }

    /// Cambia el texto de un aviso y le deja «Abrir en Paperclip» (sin «Ver en vivo»: se edita al cerrarse).
    /// `false` si no se pudo (sin conexión con Telegram); si el mensaje ya no está o ya decía eso, no hay nada
    /// más que hacer y da `true`.
    @discardableResult
    func editNotice(_ messageId: Int, html: String, href: String?) async -> Bool {
        guard let bot, let chatId = noticeChatId else { return false }
        func params(_ links: Links) -> [String: Any] {
            var params: [String: Any] = [
                "chat_id": chatId, "message_id": messageId, "text": html, "parse_mode": "HTML",
                "link_preview_options": ["is_disabled": true],
            ]
            params["reply_markup"] = noticeKeyboard(href, preview: nil, label: nil, links: links)
            return params
        }
        do {
            try await withLinkFallback(preview: false) { links in try await bot.send("editMessageText", params(links)) }
            return true
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

    /// «Ver en vivo» y «Abrir en Paperclip» (o `label`), cada uno en su fila, o `nil` si el teléfono no puede
    /// abrir ninguno (direcciones locales).
    func linkKeyboard(_ href: String?, preview: URL? = nil, label: String? = nil) -> [String: Any]? {
        noticeKeyboard(href, preview: preview, label: label, links: .all)
    }

    /// Los de `linkKeyboard`, sin los que Telegram rechazó (`withLinkFallback`).
    private func noticeKeyboard(_ href: String?, preview: URL?, label: String?, links: Links) -> [String: Any]? {
        guard links != .none else { return nil }
        var rows: [[[String: Any]]] = []
        if links == .all, let preview = phonePreviewURL(preview) {
            rows.append([["text": String(localized: "Open preview"), "url": preview.absoluteString]])
        }
        if let url = paperclipURL(href) {
            rows.append([["text": label ?? String(localized: "Open in Paperclip"), "url": url.absoluteString]])
        }
        return rows.isEmpty ? nil : ["inline_keyboard": rows]
    }

    /// «Ver en vivo» solo si el teléfono puede abrirla: una dirección de esta Mac (`localhost`) no.
    func phonePreviewURL(_ url: URL?) -> URL? {
        guard let url, !LivePreview.isLocal(url) else { return nil }
        return url
    }
}
