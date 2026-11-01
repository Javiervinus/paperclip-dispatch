import SwiftUI

/// «Ver en vivo» y el aviso del tope diario en el ensayo de `snapshot.zsh notifications`: el aviso de la Mac y el
/// mensaje de Telegram de una confirmación, de una tarea trabada, de una tarjeta de varios pasos (en dos pasos)
/// y de una tarea asignada, todos con algo servido; uno con una dirección de esta Mac (solo en la Mac); y el de
/// un agente que llegó a su tope. Con los mismos textos y botones que arma el código de verdad.
extension NotificationsSnapshot {
    /// Lo que un agente deja servido para revisar, con la dirección de Tailscale de la Mac.
    private static let sampleTailnetPreview = URL(string: "https://studio-mac.example.ts.net:4734/")!
    private static let sampleLocalPreview = URL(string: "http://localhost:4734/")!

    static func livePreviewCases(
        channel: TelegramChannel,
        stuck: AttentionItem,
        wake: WakeButton
    ) -> [(file: String, view: AnyView)] {
        let previewTitle = String(localized: "Open preview")
        guard let confirmation = sampleConfirmation(), let issueId = confirmation.taskId,
              let interactionId = confirmation.subject?.id
        else { return [] }
        let choices = [
            DecisionChoice(
                label: String(localized: "Approve"),
                action: .acceptInteraction(issueId: issueId, interactionId: interactionId),
                asks: nil
            ),
            DecisionChoice(
                label: String(localized: "Request changes"),
                action: .rejectInteraction(issueId: issueId, interactionId: interactionId),
                asks: String(localized: "What should change?")
            ),
        ]
        func decision(_ item: AttentionItem, prompt: DecisionPrompt, preview: URL?, progress: CardProgress? = nil)
            -> TelegramMessagePreview {
            let sent = TelegramChannel.SentDecision(
                key: 1, companyId: "", messageId: nil, html: TelegramFormat.decision(item, prompt: prompt),
                choices: prompt.choices, issueId: item.issueId, issueIdentifier: item.relatedIssue?.identifier,
                href: item.subject?.href ?? item.relatedIssue?.href, card: prompt.card,
                progress: progress ?? prompt.card.map(CardProgress.init), preview: preview?.absoluteString
            )
            return TelegramMessagePreview(
                html: channel.messageText(sent),
                buttons: channel.keyboard(for: sent).map { $0.compactMap { $0["text"] as? String } }
            )
        }
        func mac(_ item: AttentionItem, actions: [String]) -> MacNoticePreview {
            let notice = DecisionsMonitor.notice(for: item)
            return MacNoticePreview(title: notice.title, body: notice.body, actions: actions)
        }

        let prompt = DecisionPrompt(question: confirmation.detail?.promptExcerpt, choices: choices)
        let stuckPrompt = DecisionPrompt(
            question: stuck.detail?.promptExcerpt,
            choices: stuck.wakeTarget.map { [DecisionResolver.wakeChoice($0, agentName: wake.agentName)] } ?? []
        )
        let card = sampleCard(issueId: issueId, interactionId: interactionId)
        let cardPrompt = DecisionPrompt(question: confirmation.detail?.promptExcerpt, card: card)
        var secondStep = CardProgress(card)
        secondStep.answers[card.questions[0].id] = CardProgress.Answer(optionIds: ["dark"], text: nil, other: false)
        secondStep.step = 1

        let task = AssignedTaskNotice(
            issueId: UUID().uuidString.lowercased(),
            identifier: "ACME-231",
            title: String(localized: "Try the new onboarding on your phone"),
            excerpt: String(localized: "It’s served on the studio Mac: open it on your phone and tell me if the steps feel too long."),
            assignerName: String(localized: "Operations"),
            projectName: String(localized: "Website"),
            href: "/ACME/issues/ACME-231"
        )
        let taskMac = AssignedTaskFormat.mac(task)
        func taskMessage(_ preview: URL?) -> TelegramMessagePreview {
            TelegramMessagePreview(
                html: channel.noticeText(AssignedTaskFormat.telegram(task), preview: preview),
                buttons: (channel.linkKeyboard(task.href)?["inline_keyboard"] as? [[[String: Any]]] ?? [])
                    .map { $0.compactMap { $0["text"] as? String } }
            )
        }

        return [
            ("mac-preview", AnyView(MacScene(notices: [mac(confirmation, actions: [previewTitle])]))),
            ("mac-preview-stuck", AnyView(MacScene(notices: [mac(stuck, actions: [wake.title, previewTitle])]))),
            ("mac-preview-task", AnyView(MacScene(notices: [
                MacNoticePreview(title: taskMac.title, body: taskMac.body, actions: [previewTitle]),
            ]))),
            ("telegram-preview", AnyView(TelegramScene(messages: [
                decision(confirmation, prompt: prompt, preview: sampleTailnetPreview),
            ]))),
            ("telegram-preview-stuck", AnyView(TelegramScene(messages: [
                decision(stuck, prompt: stuckPrompt, preview: sampleTailnetPreview),
            ]))),
            ("telegram-preview-card", AnyView(TelegramScene(messages: [
                decision(confirmation, prompt: cardPrompt, preview: sampleTailnetPreview),
                decision(confirmation, prompt: cardPrompt, preview: sampleTailnetPreview, progress: secondStep),
            ]))),
            ("telegram-preview-task", AnyView(TelegramScene(messages: [taskMessage(sampleTailnetPreview)]))),
            // Una dirección de esta Mac: en la Mac sí, en Telegram no.
            ("telegram-preview-local", AnyView(TelegramScene(messages: [
                decision(confirmation, prompt: prompt, preview: sampleLocalPreview),
            ]))),
        ]
    }

    static func runLimitCases(channel: TelegramChannel) -> [(file: String, view: AnyView)] {
        // A media tarde: se reinicia hoy, con la hora de esta Mac.
        let now = Date()
        let notice = RunLimitNotice(
            agentName: String(localized: "Chief of Staff"),
            limit: 60,
            resetsAt: RunLimit.utcDay(containing: now).end,
            href: "/ACME/agents/chief-of-staff"
        )
        let label = String(localized: "Open agent")
        let buttons = (channel.linkKeyboard(notice.href, label: label)?["inline_keyboard"] as? [[[String: Any]]] ?? [])
            .map { $0.compactMap { $0["text"] as? String } }
        return [
            ("mac-run-limit", AnyView(MacScene(notices: [
                MacNoticePreview(title: RunLimitFormat.title(notice), body: RunLimitFormat.body(notice, now: now), action: label),
            ]))),
            ("telegram-run-limit", AnyView(TelegramScene(messages: [
                TelegramMessagePreview(html: RunLimitFormat.telegram(notice, now: now), buttons: buttons),
            ]))),
        ]
    }

    /// Una confirmación de una tarea (`request_confirmation`) como la manda Paperclip 2026.1023.0.
    private static func sampleConfirmation() -> AttentionItem? {
        let issueId = UUID().uuidString.lowercased()
        let json: [String: Any] = [
            "id": "issue_thread_interaction:\(UUID().uuidString.lowercased())",
            "sourceKind": "issue_thread_interaction",
            "subject": [
                "kind": "interaction",
                "id": UUID().uuidString.lowercased(),
                "title": String(localized: "Approve the new landing page"),
                "href": "/ACME/issues/ACME-230",
                "metadata": ["kind": "request_confirmation", "issueId": issueId],
            ],
            "relatedIssue": [
                "kind": "issue",
                "id": issueId,
                "identifier": "ACME-230",
                "title": String(localized: "Landing page, round 2"),
                "href": "/ACME/issues/ACME-230",
            ],
            "project": ["name": String(localized: "Website")],
            "originAgentName": String(localized: "Operations"),
            "detail": [
                "promptExcerpt": String(localized: "It’s served on the studio Mac: check the animations on your phone before approving."),
            ],
            "inlineResolvable": true,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: json) else { return nil }
        return try? JSONDecoder().decode(AttentionItem.self, from: data)
    }

    /// Un formulario de dos preguntas (`ask_user_questions`).
    private static func sampleCard(issueId: String, interactionId: String) -> DecisionCard {
        var card = DecisionCard(kind: .form, issueId: issueId, interactionId: interactionId)
        card.questions = [
            DecisionCard.Question(
                id: "theme", prompt: String(localized: "Which hero do you prefer?"), help: nil, mode: .single, required: true,
                options: [
                    DecisionCard.Option(id: "dark", label: String(localized: "The dark one"), detail: nil, asksText: false),
                    DecisionCard.Option(id: "light", label: String(localized: "The light one"), detail: nil, asksText: false),
                ],
                placeholder: nil, maxLength: nil
            ),
            DecisionCard.Question(
                id: "launch", prompt: String(localized: "When do we publish it?"), help: nil, mode: .single, required: true,
                options: [
                    DecisionCard.Option(id: "today", label: String(localized: "Today"), detail: nil, asksText: false),
                    DecisionCard.Option(id: "monday", label: String(localized: "On Monday"), detail: nil, asksText: false),
                ],
                placeholder: nil, maxLength: nil
            ),
        ]
        return card
    }
}
