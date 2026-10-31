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
        guard item.inlineResolvable, let subjectId = item.subject?.id else { return prompt }
        do {
            switch item.sourceKind {
            case "issue_thread_interaction":
                guard let issueId = item.subject?.metadata?.issueId else { return prompt }
                return try await interactionPrompt(issueId: issueId, interactionId: subjectId, fallback: prompt)
            case "approval":
                prompt.choices = [
                    DecisionChoice(label: "Aprobar", action: .approve(approvalId: subjectId), asks: nil),
                    DecisionChoice(label: "Rechazar", action: .rejectApproval(approvalId: subjectId), asks: nil),
                    DecisionChoice(
                        label: "Pedir cambios",
                        action: .requestRevision(approvalId: subjectId),
                        asks: "¿Qué cambios pides?"
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
                ["optionId": optionId, "idempotencyKey": "paperclip-app:\(decisionId):\(optionId)"]
            )
        }
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
                ? payload.rejectReasonLabel ?? payload.declineReasonPlaceholder ?? "¿Por qué?"
                : nil
            prompt.choices = [
                DecisionChoice(
                    label: payload.acceptLabel ?? "Confirmar",
                    action: .acceptInteraction(issueId: issueId, interactionId: interactionId),
                    asks: nil
                ),
                DecisionChoice(
                    label: payload.rejectLabel ?? "Rechazar",
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
                    asks: option.freeText == true ? option.description ?? "Escribe tu respuesta." : nil
                )
            }
            if question.allowOther == true {
                prompt.choices.append(DecisionChoice(
                    label: "Otra respuesta…",
                    action: .answer(issueId: issueId, interactionId: interactionId, questionId: question.id, optionId: nil),
                    asks: "Escribe tu respuesta."
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
}
