import Foundation
import Observation

/// El bot de Telegram de Decisions. Cada decisión nueva llega como un mensaje con sus botones; lo que se
/// toca o se escribe ahí se aplica en Paperclip con la sesión de la app, a nombre del usuario.
///
/// - El bot es del usuario (lo crea con @BotFather). La app lo atiende con `getUpdates`, así que no hace
///   falta una dirección pública ni Tailscale. Funciona mientras la Mac y la app estén encendidas.
/// - Solo habla con el chat que se vinculó con el código de Ajustes; a los demás no les contesta.
/// - Responder con texto a un mensaje de una decisión lo deja como comentario en su tarea.
/// - «Explícamela» cuenta la decisión con el contexto de su tarea (`DecisionExplainer`).
/// - Es un bot de avisos: no conversa. Lo que se escribe cuenta solo en dos casos: como el texto que pidió un
///   botón (un motivo, otra respuesta), o como comentario para el agente si se responde a una decisión. Un
///   mensaje suelto vale como el último texto pedido, si se pidió hace poco; si no, no se aplica a nada,
///   porque puede haber varias decisiones abiertas. Preguntar lo que sea queda para un agente con su canal.
@MainActor
@Observable
final class TelegramChannel {
    private static let tokenAccount = "telegram-bot-token"
    /// Lo que Telegram deja abierta la conexión de `getUpdates` esperando mensajes.
    private static let pollSeconds = 50
    /// Margen sobre `pollSeconds` para que el pedido no se corte antes de que Telegram conteste.
    private static let pollGrace = 15
    /// Sin conexión con Telegram, la espera antes de reintentar empieza aquí y se duplica hasta `maxRetryDelay`.
    private static let retryDelay: Double = 5
    private static let maxRetryDelay: Double = 60
    /// Si otro programa atiende el mismo bot (409), cuánto esperar antes de volver a intentarlo.
    private static let conflictDelay: Double = 30
    /// Si llegan más que esto a la vez (p. ej. al vincular con muchas pendientes), el resto se resume en un mensaje.
    private static let batchLimit = 5
    /// Lo que ya se contestó aquí puede seguir unos segundos en Decisions; no se vuelve a mandar.
    private static let reopenAfter: TimeInterval = 5 * 60
    /// Cuánto se recuerda una decisión cerrada (y un texto pedido sin contestar) antes de olvidarla.
    private static let keepClosed: TimeInterval = 7 * 24 * 60 * 60
    /// A un mensaje suelto se le contesta cómo se usa el bot como mucho una vez en este tiempo; si no, silencio.
    private static let helpInterval: TimeInterval = 24 * 60 * 60
    /// Un mensaje suelto cuenta como el último texto que pidió un botón si se pidió hace menos que esto.
    private static let replyWindow: TimeInterval = 10 * 60
    /// «Escribiendo…» dura 5 s en Telegram: se renueva un poco antes mientras se arma una explicación.
    private static let typingRenewal: Double = 4
    private static let pairingCodeLength = 8

    /// Lo que se recuerda entre aperturas, en Application Support. El token va aparte, en el llavero.
    struct State: Codable {
        var enabled = true
        var botUsername: String?
        /// Para vincular el chat: llega como `/start <código>` desde el enlace de Ajustes.
        var pairingCode: String?
        var chatId: Int64?
        var chatName: String?
        var offset = 0
        var nextKey = 1
        /// Por id de elemento de Decisions.
        var messages: [String: SentDecision] = [:]
        /// Por id del mensaje que pidió el texto.
        var replies: [String: PendingReply] = [:]
        /// Lo nuevo va como opcional, para leer el archivo de una versión anterior sin perder el chat.
        var explain: Bool?
        var explainer: DecisionExplainer.Engine?
        /// El modelo elegido para cada CLI; sin elegir, el que el CLI tenga por defecto.
        var explainModels: [String: String]?
        /// Para «Otro comando…».
        var explainCommand: String?
        /// La última vez que se explicó, ante un mensaje suelto, que el bot solo avisa.
        var helpSentAt: Date?
    }

    struct SentDecision: Codable {
        /// Va en los botones (`c:<key>:<n>`); Telegram deja 64 bytes.
        var key: Int
        var companyId: String
        /// `nil` si no se mandó (llegaron demasiadas de una vez).
        var messageId: Int?
        var html: String
        var choices: [DecisionChoice]
        var issueId: String?
        var issueIdentifier: String?
        var closedAt: Date?
        /// La decisión en texto simple, para explicarla.
        var brief: String?
        var href: String?
        /// Si ya tiene el botón «Explícamela».
        var explainable: Bool?
        /// Tarea trabada cuyo agente ya va en camino: lo que dice el mensaje en lugar del botón, que espera en
        /// `choices` hasta que la corrida termine.
        var onTheWay: String?
    }

    struct PendingReply: Codable {
        var itemId: String
        var choice: Int
        var createdAt: Date
    }

    private(set) var state: State
    private(set) var hasToken: Bool
    /// Lo que no anda, para mostrarlo en Ajustes.
    private(set) var problem: String?

    /// Para que Decisions se revise ya (después de contestar o de vincular el chat).
    @ObservationIgnored var requestRefresh: (() -> Void)?
    @ObservationIgnored private let resolver: DecisionResolver
    @ObservationIgnored private let explainer: DecisionExplainer
    @ObservationIgnored private let serverURL: URL
    @ObservationIgnored private var bot: TelegramBotAPI?
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var sending: Set<String> = []
    @ObservationIgnored private var working: Set<String> = []
    @ObservationIgnored private var explaining: Set<String> = []
    /// En el ensayo de Ajustes no se guarda nada.
    @ObservationIgnored private var ephemeral = false

    init(resolver: DecisionResolver, explainer: DecisionExplainer, serverURL: URL) {
        self.resolver = resolver
        self.explainer = explainer
        self.serverURL = serverURL
        state = Self.loadState()
        let token = Keychain.read(Self.tokenAccount)
        hasToken = token != nil
        bot = token.map { TelegramBotAPI(token: $0) }
    }

    /// Para el ensayo de Ajustes: un canal con ese estado que no guarda nada ni habla con Telegram.
    init(previewing state: State, hasToken: Bool, resolver: DecisionResolver, explainer: DecisionExplainer, serverURL: URL) {
        self.resolver = resolver
        self.explainer = explainer
        self.serverURL = serverURL
        self.state = state
        self.hasToken = hasToken
        ephemeral = true
    }

    var isPaired: Bool { state.chatId != nil }

    // MARK: - Explicar decisiones (Ajustes)

    /// El botón «Explícamela» en cada decisión.
    var explainEnabled: Bool { state.explain ?? true }

    /// Al apagarlo o prenderlo, las decisiones abiertas pierden o recuperan el botón.
    func setExplainEnabled(_ enabled: Bool) {
        guard enabled != explainEnabled else { return }
        state.explain = enabled
        save()
        Task {
            for sent in state.messages.values where sent.closedAt == nil && sent.explainable == true {
                if let messageId = sent.messageId { await setKeyboard(messageId, for: sent) }
            }
        }
    }

    /// Con qué se explican.
    var engine: DecisionExplainer.Engine { state.explainer ?? .automatic }

    func setEngine(_ engine: DecisionExplainer.Engine) {
        state.explainer = engine
        save()
    }

    /// Vacío: el que el CLI tenga por defecto.
    func model(for engine: DecisionExplainer.Engine) -> String {
        state.explainModels?[engine.rawValue] ?? ""
    }

    func setModel(_ model: String, for engine: DecisionExplainer.Engine) {
        var models = state.explainModels ?? [:]
        models[engine.rawValue] = model.isEmpty ? nil : model
        state.explainModels = models
        save()
    }

    var customCommand: String { state.explainCommand ?? "" }

    func setCustomCommand(_ command: String) {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        state.explainCommand = trimmed.isEmpty ? nil : trimmed
        save()
    }

    func detectExplainers(force: Bool = false) async -> DecisionExplainer.Detection {
        await explainer.detect(force: force)
    }

    func explainerModels(for engine: DecisionExplainer.Engine) async -> [DecisionExplainer.Model] {
        await explainer.models(for: engine)
    }

    /// El enlace que abre el bot y le manda el código.
    var pairingURL: URL? {
        guard let username = state.botUsername, let code = state.pairingCode else { return nil }
        return URL(string: "https://t.me/\(username)?start=\(code)")
    }

    func start() {
        guard state.enabled, bot != nil, loop == nil else { return }
        loop = Task { [weak self] in await self?.run() }
    }

    /// Revisa el token con Telegram, lo guarda en el llavero y deja listo el código para vincular el chat.
    /// Devuelve el error para mostrarlo, o `nil` si quedó conectado.
    func connect(token raw: String) async -> String? {
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return String(localized: "Paste the token @BotFather gave you.") }
        let candidate = TelegramBotAPI(token: token)
        let me: TelegramBotAPI.User
        do {
            me = try await candidate.call("getMe")
        } catch let failure as TelegramBotAPI.Failure where failure.code == 401 || failure.code == 404 {
            return String(localized: "Telegram doesn’t recognize that token. Copy it again from @BotFather.")
        } catch {
            return String(localized: "Couldn’t reach Telegram: \(error.localizedDescription)")
        }
        guard let username = me.username else { return String(localized: "That token doesn’t belong to a bot.") }
        guard Keychain.save(token, for: Self.tokenAccount) else { return String(localized: "Couldn’t save the token in the Keychain.") }
        stop()
        state = State()
        state.botUsername = username
        state.pairingCode = Self.makePairingCode()
        save()
        bot = candidate
        hasToken = true
        problem = nil
        start()
        return nil
    }

    /// Borra el token del llavero y olvida el chat.
    func removeBot() {
        stop()
        Keychain.delete(Self.tokenAccount)
        bot = nil
        hasToken = false
        problem = nil
        state = State()
        save()
    }

    func setEnabled(_ enabled: Bool) {
        state.enabled = enabled
        save()
        if enabled {
            start()
            requestRefresh?()
        } else {
            stop()
        }
    }

    func sendTest() async -> String? {
        guard isPaired else { return nil }
        do {
            try await sendText(
                String(localized: """
                    This is how Paperclip decisions reach you: with their buttons. If you reply to one with text, \
                    I’ll post it as a comment on its task.
                    """)
            )
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Cada vuelta del monitor de Decisions, por company: manda lo nuevo y cierra lo que ya no está pendiente.
    func update(companyId: String, items: [AttentionItem], complete: Bool) {
        guard state.enabled, bot != nil, isPaired else { return }
        Task { await sync(companyId: companyId, items: items, complete: complete) }
    }

    // MARK: - Decisions → Telegram

    private func sync(companyId: String, items: [AttentionItem], complete: Bool) async {
        let now = Date()
        let current = Set(items.map(\.id))
        // Lo que se resolvió en otro lado (en Paperclip, por un agente, o se pospuso). Si la lista no vino
        // entera, lo que falta puede estar en la página siguiente.
        for (id, sent) in state.messages
        where complete && sent.companyId == companyId && sent.closedAt == nil && !current.contains(id)
            && !working.contains(id) {
            await close(id)
        }

        // Un mensaje guardado sin «Explícamela» (de un archivo de estado anterior al botón) lo recibe una vez.
        for item in items {
            guard let sent = state.messages[item.id], sent.closedAt == nil, sent.explainable != true,
                  let messageId = sent.messageId
            else { continue }
            let prompt = await resolver.prompt(for: item)
            state.messages[item.id]?.brief = TelegramFormat.brief(item, prompt: prompt)
            state.messages[item.id]?.href = item.subject?.href ?? item.relatedIssue?.href
            state.messages[item.id]?.explainable = true
            if let updated = state.messages[item.id] { await setKeyboard(messageId, for: updated) }
        }

        // Una tarea trabada que ya salió pierde o recupera «Despertar a …» según su agente vaya en camino o no.
        for item in items where item.wakeTarget != nil && !sending.contains(item.id) {
            await refreshWake(item)
        }

        let fresh = items.filter { item in
            guard !sending.contains(item.id) else { return false }
            guard let sent = state.messages[item.id] else { return true }
            // Volvió a estar pendiente un rato después de cerrarse.
            return sent.closedAt.map { now.timeIntervalSince($0) > Self.reopenAfter } ?? false
        }
        let batch = fresh.prefix(Self.batchLimit)
        let rest = fresh.dropFirst(Self.batchLimit)
        // Todo se reserva antes del primer envío: otra vuelta que llegue mientras tanto (p. ej. al contestar
        // desde aquí) no manda de nuevo lo que todavía está en cola.
        for item in rest {
            state.messages[item.id] = SentDecision(
                key: 0, companyId: companyId, messageId: nil, html: "", choices: [],
                issueId: item.issueId, issueIdentifier: item.relatedIssue?.identifier
            )
        }
        sending.formUnion(batch.map(\.id))
        for item in batch {
            await send(item, companyId: companyId)
            sending.remove(item.id)
        }
        if !rest.isEmpty {
            try? await sendText(String(localized: "And \(rest.count) more pending: they’re in Paperclip."), link: decisionsURL())
        }

        state.messages = state.messages.filter { _, sent in
            sent.closedAt.map { now.timeIntervalSince($0) < Self.keepClosed } ?? true
        }
        state.replies = state.replies.filter { now.timeIntervalSince($0.value.createdAt) < Self.keepClosed }
        save()
    }

    /// Ya no está pendiente: se dice en el mensaje y se le quitan los botones.
    private func close(_ id: String) async {
        guard let sent = state.messages[id], sent.closedAt == nil else { return }
        state.messages[id]?.closedAt = Date()
        if let messageId = sent.messageId {
            await edit(messageId, html: sent.html + "\n\n" + String(localized: "☑️ <i>No longer pending.</i>"))
        }
    }

    /// Quien llama la marca en `sending` mientras tanto, para que otra vuelta no la mande dos veces.
    private func send(_ item: AttentionItem, companyId: String) async {
        guard let bot, let chatId = state.chatId else { return }
        let prompt = await resolver.prompt(for: item)
        var sent = SentDecision(
            key: state.nextKey,
            companyId: companyId,
            messageId: nil,
            html: TelegramFormat.decision(item, prompt: prompt),
            choices: prompt.choices + (prompt.onTheWay.map { [$0.choice] } ?? []),
            issueId: item.issueId,
            issueIdentifier: item.relatedIssue?.identifier,
            brief: TelegramFormat.brief(item, prompt: prompt),
            href: item.subject?.href ?? item.relatedIssue?.href,
            explainable: true,
            onTheWay: prompt.onTheWay?.text
        )
        state.nextKey += 1

        func params(link: Bool) -> [String: Any] {
            [
                "chat_id": chatId,
                "text": TelegramFormat.withProgress(sent),
                "parse_mode": "HTML",
                "link_preview_options": ["is_disabled": true],
                "reply_markup": ["inline_keyboard": keyboard(for: sent, link: link)],
            ]
        }

        let message: TelegramBotAPI.MessageReference
        do {
            message = try await bot.call("sendMessage", params(link: true))
        } catch let failure as TelegramBotAPI.Failure where failure.reason.contains("BUTTON_URL_INVALID") {
            // Telegram no acepta direcciones locales; sin el enlace, igual se contesta con los botones.
            guard let retry: TelegramBotAPI.MessageReference = try? await bot.call("sendMessage", params(link: false))
            else { return }
            message = retry
        } catch {
            // Se vuelve a intentar en la próxima vuelta del monitor.
            problem = String(localized: "Couldn’t send a decision: \(error.localizedDescription)")
            return
        }
        sent.messageId = message.messageId
        state.messages[item.id] = sent
    }

    /// Una fila por opción (`c:<key>:<n>`), «Explícamela» (`e:<key>`) y el enlace a Paperclip. Sin opciones si
    /// el agente ya va en camino.
    func keyboard(for sent: SentDecision, link: Bool = true) -> [[[String: Any]]] {
        var rows: [[[String: Any]]] = sent.onTheWay != nil ? [] : sent.choices.indices.map { index in
            [["text": sent.choices[index].label, "callback_data": "c:\(sent.key):\(index)"]]
        }
        if explainEnabled { rows.append([["text": String(localized: "💡 Explain it to me"), "callback_data": "e:\(sent.key)"]]) }
        if link, let url = paperclipURL(sent.href) {
            rows.append([["text": String(localized: "Open in Paperclip"), "url": url.absoluteString]])
        }
        return rows
    }

    // MARK: - Telegram → Paperclip

    private func run() async {
        var delay = Self.retryDelay
        while !Task.isCancelled, let bot {
            do {
                let updates: [TelegramBotAPI.Update] = try await bot.call(
                    "getUpdates",
                    [
                        "offset": state.offset,
                        "timeout": Self.pollSeconds,
                        "allowed_updates": ["message", "callback_query"],
                    ],
                    timeout: TimeInterval(Self.pollSeconds + Self.pollGrace)
                )
                problem = nil
                delay = Self.retryDelay
                for update in updates {
                    state.offset = update.updateId + 1
                    if let callback = update.callbackQuery {
                        await handle(callback)
                    } else if let message = update.message {
                        await handle(message)
                    }
                }
                if !updates.isEmpty { save() }
            } catch _ where Task.isCancelled {
                // Se quitó o cambió el bot (`stop`): esta vuelta ya no es la vigente y no toca nada.
                return
            } catch let failure as TelegramBotAPI.Failure where failure.code == 401 {
                problem = String(localized: "Telegram no longer accepts the bot token. Remove it and connect it again.")
                loop = nil
                return
            } catch let failure as TelegramBotAPI.Failure where failure.code == 409 {
                problem = String(localized: "Another program is handling this bot. Use a bot just for Paperclip.")
                try? await Task.sleep(for: .seconds(Self.conflictDelay))
            } catch {
                problem = String(localized: "Can’t reach Telegram; it will retry on its own.")
                try? await Task.sleep(for: .seconds(delay))
                delay = min(delay * 2, Self.maxRetryDelay)
            }
        }
    }

    private func stop() {
        loop?.cancel()
        loop = nil
    }

    private func handle(_ callback: TelegramBotAPI.CallbackQuery) async {
        guard let bot else { return }
        // En un chat privado, el id del chat es el de la persona.
        guard callback.from.id == state.chatId else {
            try? await bot.send("answerCallbackQuery", ["callback_query_id": callback.id])
            return
        }
        let parts = (callback.data ?? "").split(separator: ":")
        if parts.count == 2, parts[0] == "e", let key = Int(parts[1]),
           let (itemId, sent) = state.messages.first(where: { $0.value.key == key }) {
            guard explainEnabled else {
                await answer(callback, String(localized: "“Explain decisions” is turned off in Settings."))
                return
            }
            await answer(callback, String(localized: "Reading the task…"))
            // Tarda unos segundos: mientras, el bot sigue atendiendo los demás botones.
            Task { await explain(itemId: itemId, replyTo: sent.messageId) }
            return
        }
        guard parts.count == 3, parts[0] == "c", let key = Int(parts[1]), let index = Int(parts[2]),
              let (itemId, sent) = state.messages.first(where: { $0.value.key == key }),
              sent.choices.indices.contains(index)
        else {
            await answer(callback, String(localized: "This decision is gone."))
            return
        }
        guard sent.closedAt == nil else {
            await answer(callback, String(localized: "No longer pending."))
            return
        }
        let choice = sent.choices[index]
        if let asks = choice.asks {
            await answer(callback, nil)
            await askText(asks, for: choice, itemId: itemId, index: index, replyTo: sent.messageId)
            return
        }
        if case let .wakeAgent(_, agentName) = choice.action {
            await answer(callback, String(localized: "Waking up \(agentName ?? String(localized: "the agent"))…"))
        } else {
            await answer(callback, String(localized: "Sending to Paperclip…"))
        }
        await apply(itemId: itemId, choice: index, text: nil)
    }

    private func handle(_ message: TelegramBotAPI.Message) async {
        guard message.chat.type == "private" else { return }
        let text = (message.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let chatId = state.chatId else {
            await pair(message, text: text)
            return
        }
        guard message.chat.id == chatId, !text.isEmpty else { return }
        if text.hasPrefix("/start") {
            try? await sendText(String(localized: "You’re already connected: Paperclip decisions reach you here."))
            return
        }
        if let replied = message.replyToMessage?.messageId {
            if let pending = state.replies.removeValue(forKey: String(replied)) {
                await apply(itemId: pending.itemId, choice: pending.choice, text: text, replyTo: message.messageId)
                return
            }
            if let (_, sent) = state.messages.first(where: { $0.value.messageId == replied }) {
                await comment(text, on: sent, replyTo: message.messageId)
                return
            }
        } else if let (key, pending) = state.replies.max(by: { $0.value.createdAt < $1.value.createdAt }),
                  Date().timeIntervalSince(pending.createdAt) < Self.replyWindow {
            // Sin «Responder»: es el texto del último botón que lo pidió (el último que se tocó). La respuesta
            // dice a qué decisión fue.
            state.replies.removeValue(forKey: key)
            await apply(itemId: pending.itemId, choice: pending.choice, text: text, replyTo: message.messageId)
            return
        }
        // Es un bot de avisos: no conversa. Preguntar lo que sea es cosa de un agente. Una vez al día dice cómo
        // se usa, para que quien escribe sepa que el bot anda; el resto, silencio.
        if let last = state.helpSentAt, Date().timeIntervalSince(last) < Self.helpInterval { return }
        state.helpSentAt = Date()
        save()
        try? await sendText(
            String(localized: """
                This bot only notifies you about Paperclip decisions: answer them with their buttons. To write to \
                a decision’s agent, press and hold its message, tap Reply, and type: it arrives as a comment.
                """),
            replyTo: message.messageId
        )
    }

    private func pair(_ message: TelegramBotAPI.Message, text: String) async {
        guard let bot, let code = state.pairingCode else { return }
        let given = text.hasPrefix("/start")
            ? text.dropFirst("/start".count).trimmingCharacters(in: .whitespaces)
            : text
        guard given.caseInsensitiveCompare(code) == .orderedSame else {
            if text.hasPrefix("/start") {
                try? await bot.send("sendMessage", [
                    "chat_id": message.chat.id,
                    "text": String(localized: "To connect this bot, open it with the link in Paperclip Settings on your Mac."),
                ])
            }
            return
        }
        state.chatId = message.chat.id
        state.chatName = message.from?.firstName
        state.pairingCode = nil
        save()
        try? await sendText(
            String(localized: """
                Done: Paperclip decisions reach you here, with their buttons. “Explain it to me” tells you what \
                each one is about, and if you reply to one with text, it reaches the agent as a comment on its task.
                """)
        )
        requestRefresh?()
    }

    private func askText(_ asks: String, for choice: DecisionChoice, itemId: String, index: Int, replyTo: Int?) async {
        guard let bot, let chatId = state.chatId else { return }
        var params: [String: Any] = [
            "chat_id": chatId,
            "text": "<b>\(TelegramFormat.escape(choice.label))</b>\n\(TelegramFormat.escape(asks))",
            "parse_mode": "HTML",
            "reply_markup": [
                "force_reply": true,
                "input_field_placeholder": String(asks.prefix(64)),
            ],
        ]
        if let replyTo { params["reply_parameters"] = ["message_id": replyTo, "allow_sending_without_reply": true] }
        guard let prompt: TelegramBotAPI.MessageReference = try? await bot.call("sendMessage", params) else { return }
        // Si ya se había pedido un texto para esta decisión (se tocó otro botón), vale el último.
        state.replies = state.replies.filter { $0.value.itemId != itemId }
        state.replies[String(prompt.messageId)] = PendingReply(itemId: itemId, choice: index, createdAt: Date())
        save()
    }

    /// `replyTo`: el mensaje con el texto, para confirmar ahí a qué decisión fue.
    private func apply(itemId: String, choice index: Int, text: String?, replyTo: Int? = nil) async {
        guard let sent = state.messages[itemId], sent.choices.indices.contains(index), !working.contains(itemId)
        else { return }
        guard sent.closedAt == nil else {
            // P. ej. se escribió el motivo pedido y mientras tanto se resolvió en otro lado.
            try? await sendText(String(localized: "That decision is no longer pending: I didn’t change anything."), replyTo: sent.messageId)
            return
        }
        working.insert(itemId)
        defer { working.remove(itemId) }
        let choice = sent.choices[index]
        if case let .wakeAgent(target, agentName) = choice.action {
            await wake(target, agentName: agentName, itemId: itemId, sent: sent)
            return
        }
        do {
            try await resolver.perform(choice.action, text: text)
        } catch let invalid as DecisionResolver.InvalidText {
            // P. ej. un monto que no es un número: no se mandó nada y se vuelve a pedir.
            await askText(invalid.prompt, for: choice, itemId: itemId, index: index, replyTo: sent.messageId)
            return
        } catch {
            if await resolver.isPending(itemId: itemId, companyId: sent.companyId) == false {
                // Se resolvió o se canceló en otro lado (en la Mac, por el agente) antes de que llegara esto.
                await close(itemId)
                try? await sendText(String(localized: "It was no longer pending in Paperclip: I didn’t change anything."), replyTo: sent.messageId)
            } else {
                try? await sendText(String(localized: "Couldn’t do it: \(error.localizedDescription)"), replyTo: sent.messageId)
            }
            requestRefresh?()
            return
        }
        state.messages[itemId]?.closedAt = Date()
        save()
        var status = String(localized: "✅ <b>You answered:</b> \(TelegramFormat.escape(choice.label))")
        if let text { status += "\n<i>\(TelegramFormat.escape(text))</i>" }
        if let messageId = sent.messageId { await edit(messageId, html: sent.html + "\n\n" + status) }
        if let replyTo {
            try? await sendText(
                String(localized: "✅ Sent to \(sent.issueIdentifier ?? "Paperclip"): “\(choice.label)”, with your text."),
                replyTo: replyTo
            )
        }
        requestRefresh?()
    }

    /// «Despertar a …»: una sola vez, sin reintentos. Si el agente ya trabaja (o no hacía falta), el mensaje lo
    /// dice y pierde los botones; si Paperclip lo saltó o falló, se contesta debajo y el botón queda para volver
    /// a intentarlo.
    private func wake(_ target: WakeTarget, agentName: String?, itemId: String, sent: SentDecision) async {
        let outcome = await resolver.wake(target)
        let status = TelegramFormat.wakeResult(outcome, target: target, agentName: agentName)
        if outcome.allowsRetry {
            try? await sendHTML(status, replyTo: sent.messageId)
        } else {
            state.messages[itemId]?.closedAt = Date()
            save()
            if let messageId = sent.messageId { await edit(messageId, html: sent.html + "\n\n" + status) }
        }
        requestRefresh?()
    }

    /// Revisa si el agente de una tarea trabada que ya salió va en camino y, si cambió, edita el mensaje: dice
    /// «⏳ Ya va en camino…» y pierde el botón, o lo recupera cuando la corrida termina y la tarea sigue
    /// trabada. Si no se pueden leer las corridas, queda como está hasta la próxima vuelta.
    private func refreshWake(_ item: AttentionItem) async {
        guard let target = item.wakeTarget, let sent = state.messages[item.id], sent.closedAt == nil,
              sent.messageId != nil, !working.contains(item.id),
              let agentName = sent.choices.lazy.compactMap({ choice -> String?? in
                  if case let .wakeAgent(_, name) = choice.action { name } else { nil }
              }).first,
              let progress = await resolver.wakeProgress(target)
        else { return }
        let onTheWay: String? = switch progress {
        case .idle: nil
        case let .onTheWay(running): WakeText.onTheWay(running: running, target: target, agentName: agentName)
        }
        // Mientras se leían las corridas pudo contestarse o cerrarse.
        guard let current = state.messages[item.id], current.closedAt == nil, !working.contains(item.id),
              let messageId = current.messageId, current.onTheWay != onTheWay
        else { return }
        var updated = current
        updated.onTheWay = onTheWay
        // Solo se guarda si Telegram aceptó el cambio: si no, se vuelve a intentar en la próxima vuelta.
        guard await editKeepingButtons(messageId, for: updated) else { return }
        state.messages[item.id]?.onTheWay = onTheWay
        save()
    }

    /// Cambia el texto de un mensaje y deja sus botones como están en `sent`. Dice si Telegram lo aceptó.
    private func editKeepingButtons(_ messageId: Int, for sent: SentDecision) async -> Bool {
        guard let bot, let chatId = state.chatId else { return false }
        func params(link: Bool) -> [String: Any] {
            [
                "chat_id": chatId,
                "message_id": messageId,
                "text": TelegramFormat.withProgress(sent),
                "parse_mode": "HTML",
                "link_preview_options": ["is_disabled": true],
                "reply_markup": ["inline_keyboard": keyboard(for: sent, link: link)],
            ]
        }
        do {
            try await bot.send("editMessageText", params(link: true))
            return true
        } catch let failure as TelegramBotAPI.Failure where failure.reason.contains("BUTTON_URL_INVALID") {
            return (try? await bot.send("editMessageText", params(link: false))) != nil
        } catch let failure as TelegramBotAPI.Failure where failure.reason.contains("message is not modified") {
            return true
        } catch {
            return false
        }
    }

    private func comment(_ text: String, on sent: SentDecision, replyTo: Int) async {
        guard let issueId = sent.issueId else {
            try? await sendText(String(localized: "This one isn’t from a task: answer it with the buttons or in Paperclip."), replyTo: replyTo)
            return
        }
        do {
            try await resolver.comment(text, issueId: issueId)
            try? await sendText(
                String(localized: "💬 Comment added to \(sent.issueIdentifier ?? String(localized: "the task")). Paperclip will let the agent know."),
                replyTo: replyTo
            )
        } catch {
            try? await sendText(String(localized: "Couldn’t comment: \(error.localizedDescription)"), replyTo: replyTo)
        }
    }

    // MARK: - Explicar

    /// La explicación de una decisión, una vez: no es una conversación.
    private func explain(itemId: String, replyTo: Int?) async {
        guard let sent = state.messages[itemId] else { return }
        guard explainEnabled else {
            try? await sendText(String(localized: "“Explain decisions” is turned off in Settings."), replyTo: replyTo)
            return
        }
        guard !explaining.contains(itemId) else { return }
        explaining.insert(itemId)
        defer { explaining.remove(itemId) }
        let typing = Task { [weak self] in
            while !Task.isCancelled {
                await self?.sendTyping()
                try? await Task.sleep(for: .seconds(Self.typingRenewal))
            }
        }
        defer { typing.cancel() }

        let answer: String
        do {
            guard let engine = await explainer.resolve(self.engine) else { throw DecisionExplainer.ExplainError.noEngine }
            let context = await explainer.context(issueId: sent.issueId, brief: sent.brief ?? TelegramFormat.plain(sent.html))
            answer = try await explainer.explain(
                context: context,
                engine: engine,
                model: model(for: engine),
                customCommand: customCommand
            )
        } catch {
            try? await sendText(String(localized: "Couldn’t explain it: \(error.localizedDescription)"), replyTo: replyTo)
            return
        }

        let html = "💡 \(TelegramFormat.markdown(answer))\n\n" +
            String(localized: "<i>To ask the agent something, reply to the decision.</i>")
        do {
            try await sendHTML(html, replyTo: replyTo)
        } catch {
            // Si Telegram no acepta el formato, va como texto simple.
            try? await sendHTML(TelegramFormat.escape(answer), replyTo: replyTo)
        }
    }

    // MARK: - Mensajes

    private func sendHTML(_ html: String, replyTo: Int?) async throws {
        guard let bot, let chatId = state.chatId else { return }
        var params: [String: Any] = [
            "chat_id": chatId,
            "text": html,
            "parse_mode": "HTML",
            "link_preview_options": ["is_disabled": true],
        ]
        if let replyTo { params["reply_parameters"] = ["message_id": replyTo, "allow_sending_without_reply": true] }
        try await bot.send("sendMessage", params)
    }

    private func sendTyping() async {
        guard let bot, let chatId = state.chatId else { return }
        try? await bot.send("sendChatAction", ["chat_id": chatId, "action": "typing"])
    }

    /// Cambia solo los botones de un mensaje.
    private func setKeyboard(_ messageId: Int, for sent: SentDecision) async {
        guard let bot, let chatId = state.chatId else { return }
        func params(link: Bool) -> [String: Any] {
            ["chat_id": chatId, "message_id": messageId, "reply_markup": ["inline_keyboard": keyboard(for: sent, link: link)]]
        }
        do {
            try await bot.send("editMessageReplyMarkup", params(link: true))
        } catch let failure as TelegramBotAPI.Failure where failure.reason.contains("BUTTON_URL_INVALID") {
            try? await bot.send("editMessageReplyMarkup", params(link: false))
        } catch {
            // Si el mensaje ya no está, no pasa nada.
        }
    }

    private func sendText(_ text: String, replyTo: Int? = nil, link: URL? = nil) async throws {
        guard let bot, let chatId = state.chatId else { return }
        var params: [String: Any] = ["chat_id": chatId, "text": text]
        if let replyTo { params["reply_parameters"] = ["message_id": replyTo, "allow_sending_without_reply": true] }
        if let link {
            params["reply_markup"] = ["inline_keyboard": [[["text": String(localized: "Open in Paperclip"), "url": link.absoluteString]]]]
        }
        do {
            try await bot.send("sendMessage", params)
        } catch let failure as TelegramBotAPI.Failure where failure.reason.contains("BUTTON_URL_INVALID") {
            params["reply_markup"] = nil
            try await bot.send("sendMessage", params)
        }
    }

    /// Cambia el texto y quita los botones. Si el mensaje ya no está (lo borraron), no pasa nada.
    private func edit(_ messageId: Int, html: String) async {
        guard let bot, let chatId = state.chatId else { return }
        try? await bot.send("editMessageText", [
            "chat_id": chatId,
            "message_id": messageId,
            "text": html,
            "parse_mode": "HTML",
            "link_preview_options": ["is_disabled": true],
        ])
    }

    private func answer(_ callback: TelegramBotAPI.CallbackQuery, _ text: String?) async {
        var params: [String: Any] = ["callback_query_id": callback.id]
        if let text { params["text"] = text }
        try? await bot?.send("answerCallbackQuery", params)
    }

    /// Solo si el teléfono puede abrirla: una dirección local (127.0.0.1) no le sirve.
    private func paperclipURL(_ href: String?) -> URL? {
        guard let href, let host = serverURL.host(), !Self.isLoopback(host) else { return nil }
        return URL(string: href, relativeTo: serverURL)?.absoluteURL
    }

    private func decisionsURL() -> URL? {
        guard let host = serverURL.host(), !Self.isLoopback(host) else { return nil }
        return serverURL
    }

    private static func isLoopback(_ host: String) -> Bool {
        host == "localhost" || host == "::1" || host.hasPrefix("127.")
    }

    // MARK: - Lo que se guarda

    private static var stateURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support
            .appending(path: Bundle.main.bundleIdentifier ?? AppConfig.appName, directoryHint: .isDirectory)
            .appending(path: "telegram.json")
    }

    private static func loadState() -> State {
        guard let data = try? Data(contentsOf: stateURL),
              let state = try? JSONDecoder().decode(State.self, from: data)
        else { return State() }
        return state
    }

    private func save() {
        guard !ephemeral else { return }
        let url = Self.stateURL
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(state).write(to: url, options: .atomic)
        } catch {
            problem = String(localized: "Couldn’t save the bot’s state: \(error.localizedDescription)")
        }
    }

    static func makePairingCode() -> String {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        return String((0..<pairingCodeLength).map { _ in alphabet[Int.random(in: 0..<alphabet.count)] })
    }
}

/// Cómo se ve una decisión en Telegram (HTML de la Bot API: b, i, code, blockquote).
enum TelegramFormat {
    private static let detailsLimit = 1200

    static func decision(_ item: AttentionItem, prompt: DecisionPrompt) -> String {
        var lines: [String] = []
        var header = "<b>\(escape(kindTitle(item)))</b>"
        if let project = item.project?.name { header += " · \(escape(project))" }
        lines.append(header)

        let title = item.subject?.title
        if let title { lines.append("<b>\(escape(title))</b>") }
        if let question = prompt.question, question != title { lines.append(escape(question)) }
        if let details = prompt.details?.trimmingCharacters(in: .whitespacesAndNewlines), !details.isEmpty {
            lines.append("<blockquote expandable>\(markdown(truncated(details)))</blockquote>")
        }

        let origin = [item.originAgentName, issueLine(item)].compactMap { $0 }.joined(separator: " · ")
        if !origin.isEmpty { lines.append("<i>\(escape(origin))</i>") }
        if prompt.choices.isEmpty && prompt.onTheWay == nil { lines.append(String(localized: "Answer it in Paperclip.")) }
        return lines.joined(separator: "\n")
    }

    /// El mensaje con «⏳ Ya va en camino…» al final, si el agente de la tarea trabada ya tiene una corrida.
    static func withProgress(_ sent: TelegramChannel.SentDecision) -> String {
        sent.onTheWay.map { sent.html + "\n\n" + escape($0) } ?? sent.html
    }

    /// Cómo terminó el botón «Despertar a …».
    static func wakeResult(_ outcome: WakeOutcome, target: WakeTarget, agentName: String?) -> String {
        let text = WakeText.result(outcome, target: target, agentName: agentName)
        let mark = switch outcome {
        case .accepted, .alreadyRunning: "✅"
        case .notStuck: "☑️"
        case .skipped: "⏭️"
        case .failed: "❌"
        }
        var html = "\(mark) <b>\(escape(text.title)).</b> \(escape(text.body))"
        if outcome.allowsRetry { html += "\n" + String(localized: "<i>You can press the button again.</i>") }
        return html
    }

    /// La decisión en texto simple, para dársela al modelo que la explica.
    static func brief(_ item: AttentionItem, prompt: DecisionPrompt) -> String {
        var lines = [String(localized: "Type: \(kindTitle(item))")]
        if let title = item.subject?.title { lines.append(String(localized: "Title: \(title)")) }
        if let question = prompt.question { lines.append(String(localized: "Question: \(question)")) }
        if let details = prompt.details, !details.isEmpty { lines.append(String(localized: "Details:\n\(truncated(details))")) }
        // Si el agente va en camino, el botón para despertarlo está escondido por ahora, pero sigue siendo una opción.
        if let hold = prompt.onTheWay { lines.append(hold.text) }
        let choices = prompt.choices + (prompt.onTheWay.map { [$0.choice] } ?? [])
        if choices.isEmpty {
            lines.append(String(localized: "It’s answered on the Paperclip page."))
        } else {
            let options = choices.map { choice in
                String(localized: "“\(choice.label)”") + (choice.asks.map { String(localized: " (asks you to write: \($0))") } ?? "")
            }
            lines.append(String(localized: "Options: \(options.joined(separator: " / "))"))
        }
        if let agent = item.originAgentName { lines.append(String(localized: "Requested by: \(agent)")) }
        return lines.joined(separator: "\n")
    }

    /// El texto de un mensaje ya armado, sin las etiquetas.
    static func plain(_ html: String) -> String {
        html.replacing(#/<[^>]+>/#, with: "")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func kindTitle(_ item: AttentionItem) -> String {
        switch item.sourceKind {
        case "issue_thread_interaction":
            switch item.subject?.metadata?.kind {
            case "ask_user_questions": String(localized: "Question")
            case "suggest_tasks": String(localized: "Suggested tasks")
            case "request_item_verdicts": String(localized: "Review")
            case "connection_intent": String(localized: "Connection")
            default: String(localized: "Confirmation")
            }
        case "approval":
            item.extras.metadata?.type == "request_board_approval" ? String(localized: "Board approval") : String(localized: "Approval")
        case "decision": String(localized: "Decision")
        case "join_request": String(localized: "Access request")
        case "recovery_action": String(localized: "Recovery")
        case "productivity_review": String(localized: "Productivity review")
        case "blocker_attention": String(localized: "Stuck task")
        case "review": String(localized: "Review")
        case "failed_run": String(localized: "An agent failed")
        case "budget_alert": String(localized: "Budget")
        case "agent_error_alert": String(localized: "Agent error")
        default: String(localized: "Decision")
        }
    }

    private static func issueLine(_ item: AttentionItem) -> String? {
        guard let issue = item.relatedIssue else { return nil }
        return [issue.identifier, issue.title].compactMap { $0 }.joined(separator: " ")
    }

    private static func truncated(_ text: String) -> String {
        guard text.count > detailsLimit else { return text }
        let cut = text.prefix(detailsLimit)
        let end = cut.lastIndex(where: \.isWhitespace) ?? cut.endIndex
        return String(cut[..<end]) + "…"
    }

    /// Lo poco de Markdown que se lee bien en Telegram: títulos y **negrita** en negrita, y `código`.
    static func markdown(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            let heading = line.drop(while: { $0 == "#" })
            if heading.count < line.count, heading.first == " " {
                return "<b>\(inline(String(heading.dropFirst())))</b>"
            }
            return inline(String(line))
        }.joined(separator: "\n")
    }

    private static func inline(_ text: String) -> String {
        escape(text)
            .replacing(#/`([^`\n]+)`/#) { "<code>\($0.1)</code>" }
            .replacing(#/\*\*([^*\n]+)\*\*/#) { "<b>\($0.1)</b>" }
    }
}
