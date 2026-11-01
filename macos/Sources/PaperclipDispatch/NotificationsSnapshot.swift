import AppKit
import SwiftUI

/// Ensayo de los avisos de una tarea trabada (`macos/snapshot.zsh notifications`), en claro y en oscuro: el
/// aviso de la Mac y el mensaje de Telegram, con un agente y con una persona, y cómo quedan después de
/// apretar «Despertar a …» (aceptado, saltado, ya en marcha, sin hacer falta o con error). No avisa ni manda
/// nada: los avisos de macOS los dibuja el sistema y el mensaje vive en Telegram, así que se dibujan aquí con
/// el mismo título, texto y botones que arma el código de verdad (`DecisionsMonitor.notice`, `WakeText`,
/// `TelegramFormat`, `TelegramChannel.keyboard`). Los archivos van en inglés (`mac-agent-light.png`).
@MainActor
enum NotificationsSnapshot {
    /// Lo que tarda SwiftUI en dibujar las ventanas.
    private static let drawTime: Duration = .seconds(2)
    /// Para que se vea el botón «Abrir en Paperclip»: con una dirección local (127.0.0.1) Telegram no lo acepta
    /// y el código no lo pone.
    private static let sampleServerURL = URL(string: "https://paperclip.example.ts.net")!
    private static let operations = (id: "00000000-0000-4000-8000-000000000001", name: String(localized: "Operations"))
    private static let chief = (id: "00000000-0000-4000-8000-000000000002", name: String(localized: "Chief of Staff"))
    private static let skippedMessage = "The previous execution has not released its environment lease. Wait for "
        + "cleanup before continuing this task."
    private static let deferredMessage = "Wakeup was deferred because this issue is already being executed by \(operations.name)."
    private static let failure = String(localized: "Paperclip returned 500: Internal server error")

    static func run(to directory: URL) async {
        let agentItem = sampleItem(
            issue: ("ACME-220", String(localized: "Redesign the pricing page")),
            blocked: ("ACME-221", String(localized: "Launch the new pricing plans")),
            agentId: operations.id
        )
        let personItem = sampleItem(
            issue: ("ACME-222", String(localized: "Review the client contract")),
            blocked: ("ACME-223", String(localized: "Send the proposal")),
            agentId: nil
        )
        let chiefItem = sampleItem(
            issue: ("ACME-219", String(localized: "Write the quarterly report for investors")),
            blocked: ("ACME-214", String(localized: "Prepare the board meeting")),
            agentId: chief.id
        )
        guard let agentItem, let personItem, let chiefItem, let target = agentItem.wakeTarget else { return }
        let button = WakeButton(target: target, agentName: operations.name)
        let channel = TelegramChannel(
            previewing: TelegramChannel.State(),
            hasToken: true,
            resolver: DecisionResolver(api: PaperclipAPI(serverURL: sampleServerURL)),
            explainer: DecisionExplainer(api: PaperclipAPI(serverURL: sampleServerURL)),
            serverURL: sampleServerURL
        )

        func mac(_ item: AttentionItem, wake: WakeButton?) -> MacNoticePreview {
            let notice = DecisionsMonitor.notice(for: item)
            return MacNoticePreview(title: notice.title, body: notice.body, action: wake?.title)
        }
        func macResult(_ outcome: WakeOutcome) -> MacNoticePreview {
            let text = WakeText.result(outcome, target: target, agentName: operations.name)
            return MacNoticePreview(title: text.title, body: text.body, action: outcome.allowsRetry ? button.title : nil)
        }
        func message(_ item: AttentionItem, agentName: String?) -> TelegramMessagePreview {
            let choices = item.wakeTarget.map { [DecisionResolver.wakeChoice($0, agentName: agentName)] } ?? []
            let prompt = DecisionPrompt(question: item.detail?.promptExcerpt, choices: choices)
            let sent = TelegramChannel.SentDecision(
                key: 1, companyId: "", messageId: nil, html: TelegramFormat.decision(item, prompt: prompt),
                choices: choices, issueId: item.issueId, issueIdentifier: item.relatedIssue?.identifier,
                href: item.subject?.href ?? item.relatedIssue?.href
            )
            return TelegramMessagePreview(html: sent.html, buttons: channel.keyboard(for: sent).map { $0.compactMap { $0["text"] as? String } })
        }
        func telegramResult(_ outcome: WakeOutcome) -> [TelegramMessagePreview] {
            let original = message(agentItem, agentName: operations.name)
            let status = TelegramFormat.wakeResult(outcome, target: target, agentName: operations.name)
            guard outcome.allowsRetry else {
                // El mensaje se edita: suma lo que pasó y pierde los botones.
                return [TelegramMessagePreview(html: original.html + "\n\n" + status, buttons: [])]
            }
            // Se contesta debajo, y el botón queda para volver a intentarlo.
            return [original, TelegramMessagePreview(html: status, buttons: [], isReply: true)]
        }

        let accepted = WakeOutcome.accepted
        let skipped = WakeOutcome.skipped(message: skippedMessage)
        let alreadyRunning = WakeOutcome.alreadyRunning(message: deferredMessage)
        let failed = WakeOutcome.failed(failure)
        var cases: [(file: String, view: AnyView)] = [
            ("mac-agent", AnyView(MacScene(notices: [mac(agentItem, wake: button)]))),
            ("mac-person", AnyView(MacScene(notices: [mac(personItem, wake: nil)]))),
            ("mac-accepted", AnyView(MacScene(notices: [macResult(accepted)]))),
            ("mac-skipped", AnyView(MacScene(notices: [macResult(skipped)]))),
            ("mac-already-running", AnyView(MacScene(notices: [macResult(alreadyRunning)]))),
            ("mac-not-stuck", AnyView(MacScene(notices: [macResult(.notStuck)]))),
            ("mac-failed", AnyView(MacScene(notices: [macResult(failed)]))),
            ("telegram-agent", AnyView(TelegramScene(messages: [message(agentItem, agentName: operations.name)]))),
            ("telegram-person", AnyView(TelegramScene(messages: [message(personItem, agentName: nil)]))),
            ("telegram-accepted", AnyView(TelegramScene(messages: telegramResult(accepted)))),
            ("telegram-skipped", AnyView(TelegramScene(messages: telegramResult(skipped)))),
            ("telegram-already-running", AnyView(TelegramScene(messages: telegramResult(alreadyRunning)))),
            ("telegram-failed", AnyView(TelegramScene(messages: telegramResult(failed)))),
            ("telegram-two-tasks", AnyView(TelegramScene(messages: [
                message(agentItem, agentName: operations.name),
                message(chiefItem, agentName: chief.name),
            ]))),
        ]
        cases += assignedTaskCases(channel: channel)
        var windows: [Snapshot.Window] = []
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            for item in cases {
                let window = sceneWindow(item.view)
                window.appearance = NSAppearance(named: appearance)
                Snapshot.hide(window)
                windows.append(Snapshot.Window(window: window, file: "\(item.file)-\(name).png"))
            }
        }
        try? await Task.sleep(for: drawTime)
        await Snapshot.capture(windows, in: directory)
    }

    /// Un `blocker_attention` como lo manda Paperclip 2026.1023.0 para una tarea trabada: `subject` es la tarea
    /// trabada (con quién la tiene) y `relatedIssue`, la que espera por ella. Sin agente, está a nombre de una
    /// persona.
    private static func sampleItem(
        issue: (identifier: String, title: String),
        blocked: (identifier: String, title: String),
        agentId: String?
    ) -> AttentionItem? {
        let json: [String: Any] = [
            "id": "blocker_attention:blocker:\(issue.identifier)",
            "sourceKind": "blocker_attention",
            "subject": [
                "kind": "issue",
                "id": UUID().uuidString.lowercased(),
                "identifier": issue.identifier,
                "title": issue.title,
                "href": "/ACME/issues/\(issue.identifier)",
                "metadata": [
                    "priority": "high",
                    "assigneeAgentId": agentId.map { $0 as Any } ?? NSNull(),
                    "assigneeUserId": agentId == nil ? "user-1" as Any : NSNull(),
                ],
            ],
            "relatedIssue": [
                "kind": "issue",
                "id": UUID().uuidString.lowercased(),
                "identifier": blocked.identifier,
                "title": blocked.title,
                "href": "/ACME/issues/\(blocked.identifier)",
            ],
            "project": ["name": "Paperclip Dispatch"],
            "whyNow": "Blocks 1 task; choose the next owner or action.",
            "decisionVerbs": [
                ["id": "unblock", "label": "Unblock"],
                ["id": "reassign", "label": "Reassign"],
                ["id": "nudge", "label": "Nudge"],
            ],
            "inlineResolvable": false,
            "detail": ["kind": "blocker", "blockingIssue": NSNull(), "blockedTaskCount": 1, "images": []],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: json) else { return nil }
        return try? JSONDecoder().decode(AttentionItem.self, from: data)
    }

    private static func sceneWindow(_ view: AnyView) -> NSWindow {
        let hosting = NSHostingController(rootView: view)
        hosting.sizingOptions = []
        let window = SnapshotableWindow(contentViewController: hosting)
        window.styleMask = [.titled, .fullSizeContentView]
        window.setContentSize(hosting.sizeThatFits(in: MainWindowController.unboundedSize))
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        return window
    }
}

// MARK: - Aviso de la Mac

/// Un aviso de macOS con el mouse encima (así se ve su botón), sobre un fondo de escritorio.
struct MacNoticePreview {
    let title: String
    let body: String
    /// El botón del aviso, si lo tiene.
    let action: String?
}

struct MacScene: View {
    let notices: [MacNoticePreview]
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 10) {
            ForEach(notices.indices, id: \.self) { index in
                MacNoticeView(notice: notices[index])
            }
        }
        .padding(28)
        .frame(width: 440)
        .background(
            LinearGradient(
                colors: colorScheme == .dark
                    ? [Color(red: 0.12, green: 0.16, blue: 0.28), Color(red: 0.25, green: 0.12, blue: 0.30)]
                    : [Color(red: 0.55, green: 0.72, blue: 0.95), Color(red: 0.85, green: 0.70, blue: 0.90)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }
}

private struct MacNoticeView: View {
    let notice: MacNoticePreview

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(notice.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 6)
                    if notice.action == nil {
                        Text("now").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                Text(notice.body).font(.system(size: 13)).lineLimit(4).fixedSize(horizontal: false, vertical: true)
            }
            if let action = notice.action {
                Text(action)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(maxWidth: 110)
                    .background(.quaternary, in: Capsule())
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

// MARK: - Mensaje de Telegram

/// Un mensaje del bot: su HTML (el mismo que se manda) y sus botones, por fila.
struct TelegramMessagePreview {
    let html: String
    let buttons: [[String]]
    /// Una respuesta del bot al mensaje de arriba.
    var isReply = false
}

struct TelegramScene: View {
    let messages: [TelegramMessagePreview]
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(messages.indices, id: \.self) { index in
                TelegramMessageView(message: messages[index], dark: colorScheme == .dark)
            }
        }
        .padding(18)
        .frame(width: 420, alignment: .leading)
        .background(colorScheme == .dark ? Color(red: 0.06, green: 0.09, blue: 0.13) : Color(red: 0.78, green: 0.86, blue: 0.74))
    }
}

private struct TelegramMessageView: View {
    let message: TelegramMessagePreview
    let dark: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            VStack(alignment: .leading, spacing: 6) {
                if message.isReply {
                    Text("Paperclip · Stuck task")
                        .font(.system(size: 12))
                        .foregroundStyle(accent)
                        .padding(.leading, 6)
                        .overlay(alignment: .leading) { Rectangle().fill(accent).frame(width: 2) }
                }
                Text(Self.attributed(message.html, dark: dark))
                    .textSelection(.disabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(dark ? Color(red: 0.13, green: 0.17, blue: 0.22) : .white, in: RoundedRectangle(cornerRadius: 14))
            ForEach(message.buttons.indices, id: \.self) { row in
                HStack(spacing: 4) {
                    ForEach(message.buttons[row], id: \.self) { label in
                        Text(label)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(Color.black.opacity(dark ? 0.35 : 0.22), in: RoundedRectangle(cornerRadius: 10))
                    }
                }
            }
        }
    }

    private var accent: Color { Color(red: 0.2, green: 0.55, blue: 0.9) }

    /// El HTML de la Bot API (b, i, code, blockquote, saltos de línea) como lo muestra Telegram, más o menos.
    static func attributed(_ html: String, dark: Bool) -> AttributedString {
        let color = dark ? "#f2f4f7" : "#111111"
        let page = "<span style=\"font-family: -apple-system; font-size: 14px; color: \(color)\">"
            + html.replacingOccurrences(of: "\n", with: "<br>")
            + "</span>"
        guard let data = page.data(using: .utf8),
              let string = try? NSAttributedString(
                  data: data,
                  options: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue],
                  documentAttributes: nil
              ),
              let converted = try? AttributedString(string, including: \.appKit)
        else { return AttributedString(TelegramFormat.plain(html)) }
        return converted
    }
}
