import Foundation

/// Cómo se contesta una decisión de Paperclip desde fuera de la página, con su API oficial.
enum DecisionAction: Codable, Hashable, Sendable {
    /// Confirmación de una tarea: aceptar o rechazar (el texto, si hay, es el motivo).
    case acceptInteraction(issueId: String, interactionId: String)
    case rejectInteraction(issueId: String, interactionId: String)
    /// Pregunta de un agente con una sola respuesta. Sin opción, el texto es la respuesta.
    case answer(issueId: String, interactionId: String, questionId: String, optionId: String?)
    /// Aprobación (el texto, si hay, es la nota de la decisión).
    case approve(approvalId: String)
    case rejectApproval(approvalId: String)
    case requestRevision(approvalId: String)
    /// Decisión con opciones.
    case decide(decisionId: String, optionId: String)
    /// Tarea trabada: despertar al agente que la tiene («Nudge»), en esa tarea.
    case wakeAgent(WakeTarget, agentName: String?)
}

/// Cómo terminó un despertar pedido con el botón.
enum WakeOutcome: Equatable, Sendable {
    /// Paperclip lo aceptó: hay una corrida del agente en la tarea.
    case accepted
    /// Paperclip lo saltó porque la tarea ya tiene una corrida en marcha (no hace falta despertarlo).
    case alreadyRunning(message: String?)
    /// Paperclip lo saltó por otro motivo. `message` es lo que dijo (en inglés), si dijo algo.
    case skipped(message: String?)
    /// La tarea ya no está a nombre de ese agente o ya se cerró: no se despertó a nadie.
    case notStuck
    /// No se pudo pedir (red, permisos, Paperclip lo rechazó).
    case failed(String)

    /// Si el botón sigue teniendo sentido: Paperclip no despertó al agente y la tarea sigue con él.
    var allowsRetry: Bool {
        switch self {
        case .skipped, .failed: true
        case .accepted, .alreadyRunning, .notStuck: false
        }
    }
}

/// Lo que se dice en el botón y después de apretarlo, igual en la Mac y en Telegram.
enum WakeText {
    static func button(_ agentName: String?) -> String {
        agentName.map { String(localized: "Wake up \($0)") } ?? String(localized: "Wake up the agent")
    }

    /// Título y texto del aviso después de apretar el botón.
    static func result(_ outcome: WakeOutcome, target: WakeTarget, agentName: String?) -> (title: String, body: String) {
        let agent = agentName ?? String(localized: "The agent")
        let task = target.issueIdentifier ?? String(localized: "the task")
        func said(_ message: String?) -> String { message.map { String(localized: " Paperclip said: “\($0)”") } ?? "" }
        return switch outcome {
        case .accepted:
            (String(localized: "Paperclip accepted the wake-up"), String(localized: "\(agent) will work on \(task)."))
        case let .alreadyRunning(message):
            (String(localized: "Paperclip skipped the wake-up"), String(localized: "\(task) already has a run in progress.") + said(message))
        case let .skipped(message):
            (String(localized: "Paperclip skipped the wake-up"), String(localized: "\(agent) still isn’t working on \(task).") + said(message))
        case .notStuck:
            (String(localized: "No wake-up needed"), String(localized: "\(task) is no longer assigned to \(agentName ?? String(localized: "that agent")), or it’s already closed."))
        case let .failed(error):
            (String(localized: "Couldn’t wake up \(agentName ?? String(localized: "the agent"))"), error)
        }
    }
}

/// Un botón: lo que dice y lo que hace.
struct DecisionChoice: Codable, Hashable, Sendable {
    let label: String
    let action: DecisionAction
    /// Si antes de aplicarla hay que escribir algo, lo que se pregunta.
    let asks: String?
}

/// Lo que hace falta para mostrar y contestar una decisión fuera de la página.
struct DecisionPrompt: Sendable {
    /// La pregunta tal como la escribió el agente.
    var question: String?
    /// Contexto en Markdown (pasos, enlaces, detalles).
    var details: String?
    /// Vacío: no se puede contestar desde fuera (se abre en Paperclip).
    var choices: [DecisionChoice] = []
}

/// Lee lo que hace falta de cada tipo de decisión y aplica la respuesta.
///
/// Solo arma botones para lo que se contesta con un toque o un texto corto: confirmaciones, preguntas de
/// una sola respuesta, aprobaciones y decisiones sin campos. Lo demás (varias preguntas, casillas, tareas
/// sugeridas, secretos) se abre en Paperclip.
@MainActor
struct DecisionResolver {
    let api: PaperclipAPI

    func prompt(for item: AttentionItem) async -> DecisionPrompt {
        var prompt = DecisionPrompt(question: item.detail?.promptExcerpt)
        // Paperclip no la deja resolver desde fuera, pero propone despertar al agente que la tiene.
        if let target = item.wakeTarget {
            prompt.choices = [Self.wakeChoice(target, agentName: await agentName(target.agentId))]
            return prompt
        }
        guard item.inlineResolvable, let subjectId = item.subject?.id else { return prompt }
        do {
            switch item.sourceKind {
            case "issue_thread_interaction":
                guard let issueId = item.subject?.metadata?.issueId else { return prompt }
                return try await interactionPrompt(issueId: issueId, interactionId: subjectId, fallback: prompt)
            case "approval":
                prompt.choices = [
                    DecisionChoice(label: String(localized: "Approve"), action: .approve(approvalId: subjectId), asks: nil),
                    DecisionChoice(label: String(localized: "Reject"), action: .rejectApproval(approvalId: subjectId), asks: nil),
                    DecisionChoice(
                        label: String(localized: "Request changes"),
                        action: .requestRevision(approvalId: subjectId),
                        asks: String(localized: "What changes do you want?")
                    ),
                ]
            case "decision":
                let decision: Decision = try await api.get("api/decisions/\(subjectId)")
                prompt.details = decision.body
                // Las que piden llenar campos se contestan en Paperclip.
                guard decision.status == nil || decision.status == "pending", decision.inputs?.isEmpty ?? true
                else { return prompt }
                prompt.choices = decision.options.map {
                    DecisionChoice(label: $0.label, action: .decide(decisionId: subjectId, optionId: $0.id), asks: nil)
                }
            default:
                break
            }
        } catch {
            // Sin los detalles igual se avisa; se contesta en Paperclip.
        }
        return prompt
    }

    func perform(_ action: DecisionAction, text: String?) async throws {
        let text = text.flatMap { $0.isEmpty ? nil : $0 }
        switch action {
        case let .acceptInteraction(issueId, interactionId):
            try await api.post("api/issues/\(issueId)/interactions/\(interactionId)/accept")
        case let .rejectInteraction(issueId, interactionId):
            try await api.post(
                "api/issues/\(issueId)/interactions/\(interactionId)/reject",
                text.map { ["reason": $0] } ?? [:]
            )
        case let .answer(issueId, interactionId, questionId, optionId):
            var answer: [String: Any] = ["questionId": questionId, "optionIds": optionId.map { [$0] } ?? []]
            if let text { answer["otherText"] = text }
            try await api.post("api/issues/\(issueId)/interactions/\(interactionId)/respond", ["answers": [answer]])
        case let .approve(approvalId):
            try await api.post("api/approvals/\(approvalId)/approve", text.map { ["decisionNote": $0] } ?? [:])
        case let .rejectApproval(approvalId):
            try await api.post("api/approvals/\(approvalId)/reject", text.map { ["decisionNote": $0] } ?? [:])
        case let .requestRevision(approvalId):
            try await api.post(
                "api/approvals/\(approvalId)/request-revision",
                text.map { ["decisionNote": $0] } ?? [:]
            )
        case let .decide(decisionId, optionId):
            // La misma clave si se toca dos veces: Paperclip la aplica una sola vez.
            try await api.post(
                "api/decisions/\(decisionId)/decide",
                ["optionId": optionId, "idempotencyKey": "paperclip-dispatch:\(decisionId):\(optionId)"]
            )
        case let .wakeAgent(target, agentName):
            // La Mac y Telegram llaman a `wake`, que dice cómo terminó; aquí solo cuenta si se aceptó.
            let outcome = await wake(target)
            guard outcome == .accepted else {
                throw WakeError(message: WakeText.result(outcome, target: target, agentName: agentName).body)
            }
        }
    }

    static func wakeChoice(_ target: WakeTarget, agentName: String?) -> DecisionChoice {
        DecisionChoice(label: WakeText.button(agentName), action: .wakeAgent(target, agentName: agentName), asks: nil)
    }

    /// Despierta al agente en la tarea, como la acción «Nudge» que propone Paperclip: con la API oficial y a
    /// nombre del usuario, igual que los botones de la web que vuelven a despertar a un agente. Solo cuando lo
    /// pide la persona (un botón); nunca solo ni para reintentar. Antes mira que la tarea siga a nombre del
    /// agente: un aviso viejo no despierta a nadie en una tarea que ya se resolvió.
    func wake(_ target: WakeTarget) async -> WakeOutcome {
        do {
            let issue: IssueSummary = try await api.get("api/issues/\(target.issueId)")
            guard issue.assigneeAgentId == target.agentId, !["done", "cancelled"].contains(issue.status ?? "")
            else { return .notStuck }
            let response: WakeResponse = try await api.post(
                "api/agents/\(target.agentId)/wakeup",
                [
                    "source": "on_demand",
                    "triggerDetail": "manual",
                    "reason": "blocked_task_nudge",
                    "payload": ["issueId": target.issueId],
                ],
                returning: WakeResponse.self
            )
            // Con una corrida, Paperclip devuelve la corrida (con `id`); si no, `status: skipped` y el motivo.
            if response.status != "skipped", response.id != nil { return .accepted }
            return response.reason == "issue_execution_deferred"
                ? .alreadyRunning(message: response.message)
                : .skipped(message: response.message)
        } catch PaperclipAPI.APIError.signedOut {
            return .failed(
                String(localized: "Paperclip didn’t allow it: the app isn’t signed in, or your user can’t wake up this agent.")
            )
        } catch PaperclipAPI.APIError.http(404, _) {
            return .notStuck
        } catch let PaperclipAPI.APIError.http(status, message) {
            return .failed(String(localized: "Paperclip returned \(status)\(message.map { ": \($0)" } ?? ".")"))
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// El nombre del agente, para el botón. `nil` si no se pudo leer.
    func agentName(_ agentId: String) async -> String? {
        let agent: AgentSummary? = try? await api.get("api/agents/\(agentId)")
        return agent?.name.flatMap { $0.isEmpty ? nil : $0 }
    }

    struct WakeError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Si sigue en Decisions. `nil` si no se pudo saber (sin red, o la lista no vino entera).
    func isPending(itemId: String, companyId: String) async -> Bool? {
        guard let attention: Attention = try? await api.get(
            "api/companies/\(companyId)/attention",
            query: [URLQueryItem(name: "limit", value: String(Attention.pageLimit))]
        ) else { return nil }
        if attention.items.contains(where: { $0.id == itemId }) { return true }
        return attention.nextCursor == nil ? false : nil
    }

    /// Un comentario en la tarea, a nombre del usuario. Paperclip despierta al agente que la tiene.
    func comment(_ text: String, issueId: String) async throws {
        try await api.post("api/issues/\(issueId)/comments", ["body": text])
    }

    private func interactionPrompt(
        issueId: String,
        interactionId: String,
        fallback: DecisionPrompt
    ) async throws -> DecisionPrompt {
        let all: [Lossy<Interaction>] = try await api.get("api/issues/\(issueId)/interactions")
        guard let interaction = all.lazy.compactMap(\.value).first(where: { $0.id == interactionId }),
              interaction.status == nil || interaction.status == "pending",
              let payload = interaction.payload
        else { return fallback }
        var prompt = fallback
        prompt.question = payload.prompt ?? fallback.question
        prompt.details = payload.detailsMarkdown

        switch interaction.kind {
        case "request_confirmation":
            // Las que proponen guardar un secreto se revisan en la página.
            guard payload.secretProposal == nil else { return prompt }
            let reason = payload.rejectRequiresReason == true
                ? payload.rejectReasonLabel ?? payload.declineReasonPlaceholder ?? String(localized: "Why?")
                : nil
            prompt.choices = [
                DecisionChoice(
                    label: payload.acceptLabel ?? String(localized: "Confirm"),
                    action: .acceptInteraction(issueId: issueId, interactionId: interactionId),
                    asks: nil
                ),
                DecisionChoice(
                    label: payload.rejectLabel ?? String(localized: "Reject"),
                    action: .rejectInteraction(issueId: issueId, interactionId: interactionId),
                    asks: reason
                ),
            ]
        case "ask_user_questions":
            // Una sola pregunta de una sola respuesta; más que eso es un formulario y va en la página.
            guard let questions = payload.questions, questions.count == 1,
                  let question = questions.first, question.selectionMode == "single"
            else { return prompt }
            prompt.question = question.prompt
            prompt.details = question.helpText ?? prompt.details
            prompt.choices = question.options.map { option in
                DecisionChoice(
                    label: option.label,
                    action: .answer(
                        issueId: issueId,
                        interactionId: interactionId,
                        questionId: question.id,
                        optionId: option.id
                    ),
                    asks: option.freeText == true ? option.description ?? String(localized: "Type your answer.") : nil
                )
            }
            if question.allowOther == true {
                prompt.choices.append(DecisionChoice(
                    label: String(localized: "Other answer…"),
                    action: .answer(issueId: issueId, interactionId: interactionId, questionId: question.id, optionId: nil),
                    asks: String(localized: "Type your answer.")
                ))
            }
        default:
            break
        }
        return prompt
    }

    // MARK: - Lo que se lee de la API

    private struct Interaction: Decodable {
        let id: String
        let kind: String?
        let status: String?
        let payload: Payload?
    }

    private struct Payload: Decodable {
        let prompt: String?
        let detailsMarkdown: String?
        let acceptLabel: String?
        let rejectLabel: String?
        let rejectRequiresReason: Bool?
        let rejectReasonLabel: String?
        let declineReasonPlaceholder: String?
        let secretProposal: PresentValue?
        let questions: [Question]?
    }

    private struct Question: Decodable {
        let id: String
        let prompt: String
        let helpText: String?
        let selectionMode: String?
        let allowOther: Bool?
        let options: [Option]
    }

    private struct Option: Decodable {
        let id: String
        let label: String
        let description: String?
        let freeText: Bool?
    }

    private struct Decision: Decodable {
        let status: String?
        let body: String?
        let options: [DecisionOption]
        let inputs: [PresentValue]?
    }

    private struct DecisionOption: Decodable {
        let id: String
        let label: String
    }

    /// La corrida (con `id`) o, si no despertó, `status: skipped` con el motivo. Se lee a la defensiva: la
    /// corrida trae muchos más campos, y uno con otra forma no tiene que hacer pasar un despertar por error.
    private struct WakeResponse: Decodable {
        let id: String?
        let status: String?
        let reason: String?
        let message: String?

        private enum CodingKeys: String, CodingKey { case id, status, reason, message }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try? container.decodeIfPresent(String.self, forKey: .id)
            status = try? container.decodeIfPresent(String.self, forKey: .status)
            reason = try? container.decodeIfPresent(String.self, forKey: .reason)
            message = try? container.decodeIfPresent(String.self, forKey: .message)
        }
    }

    private struct AgentSummary: Decodable {
        let name: String?
    }

    private struct IssueSummary: Decodable {
        let status: String?
        let assigneeAgentId: String?
    }
}
