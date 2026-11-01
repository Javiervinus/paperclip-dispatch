import Foundation

/// Lo que se contesta desde fuera de la página en los elementos de Decisions que no son tarjetas de una tarea
/// ni aprobaciones normales: solicitudes de acceso, revisiones, aprobaciones de board, corridas fallidas,
/// errores de agente y alertas de presupuesto. Cada uno con la misma ruta de la API que usa la web de
/// Paperclip (2026.1023.0) para ese botón.
enum QueueAction: Codable, Hashable, Sendable {
    case approveJoin(companyId: String, requestId: String)
    case rejectJoin(companyId: String, requestId: String)
    /// Revisión en la que la persona es la participante de la etapa. Paperclip pide un comentario para
    /// aprobar y otro para pedir cambios (el texto).
    case approveReview(issueId: String)
    case requestReviewChanges(issueId: String)
    /// Revisión trabada (sin revisor, tarjeta, corrida ni otro camino): aceptarla o pedir cambios (el texto).
    case acceptStalledReview(issueId: String)
    case requestStalledChanges(issueId: String)
    case retryRun(agentId: String, runId: String)
    /// La quita de Decisions para esta persona, como «Dismiss» en la página.
    case dismiss(companyId: String, itemKey: String)
    case keepBudgetPaused(companyId: String, incidentId: String)
    /// El texto es el presupuesto nuevo en USD. `spentCents`: lo gastado, para pedirlo de nuevo si no alcanza.
    case raiseBudget(companyId: String, incidentId: String, spentCents: Int?)
}

/// Lo que se lee de un elemento de Decisions solo para estos tipos. Se lee a la defensiva, como el resto.
struct AttentionExtras: Sendable {
    let companyId: String?
    /// Lo que se manda para quitarla de Decisions (`attention:<dedupKey>`).
    let dismissalKey: String?
    let metadata: Metadata?

    struct Metadata: Decodable, Sendable {
        /// De una aprobación: `request_board_approval`, `hire_agent`…
        let type: String?
        /// De una revisión trabada: `stalled`.
        let reviewAttentionState: String?
        /// De una corrida fallida: el agente y por qué falló.
        let agentId: String?
        let error: String?
        let retryExhaustedReason: String?
        /// De un agente con error.
        let errorReason: String?
        /// Del presupuesto, en centavos de USD; `thresholdType`: `hard` (se pausó) o `soft` (aviso).
        let amountObserved: Double?
        let amountLimit: Double?
        let scopeType: String?
        let thresholdType: String?

        private enum CodingKeys: String, CodingKey {
            case type, reviewAttentionState, agentId, error, retryExhaustedReason, errorReason
            case amountObserved, amountLimit, scopeType, thresholdType
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            func text(_ key: CodingKeys) -> String? { try? container.decodeIfPresent(String.self, forKey: key) }
            type = text(.type)
            reviewAttentionState = text(.reviewAttentionState)
            agentId = text(.agentId)
            error = text(.error)
            retryExhaustedReason = text(.retryExhaustedReason)
            errorReason = text(.errorReason)
            amountObserved = try? container.decodeIfPresent(Double.self, forKey: .amountObserved)
            amountLimit = try? container.decodeIfPresent(Double.self, forKey: .amountLimit)
            scopeType = text(.scopeType)
            thresholdType = text(.thresholdType)
        }
    }

    private enum CodingKeys: String, CodingKey { case companyId, dismissalKey, subject }
    private enum SubjectKeys: String, CodingKey { case metadata }

    /// Nunca falla: lo que no se pueda leer queda en `nil`.
    init(_ decoder: Decoder) {
        let container = try? decoder.container(keyedBy: CodingKeys.self)
        companyId = try? container?.decodeIfPresent(String.self, forKey: .companyId)
        dismissalKey = try? container?.decodeIfPresent(String.self, forKey: .dismissalKey)
        let subject = try? container?.nestedContainer(keyedBy: SubjectKeys.self, forKey: .subject)
        metadata = try? subject?.decodeIfPresent(Metadata.self, forKey: .metadata)
    }
}

extension DecisionResolver {
    /// Un texto que no sirve (p. ej. un monto que no es un número): se vuelve a pedir con `prompt`, sin mandar
    /// nada a Paperclip.
    struct InvalidText: LocalizedError {
        let prompt: String
        var errorDescription: String? { prompt }
    }

    /// Los botones de estos tipos. `nil` si el elemento no es de estos: sigue el camino de siempre. Si no se
    /// pueden leer sus detalles, queda sin botones (se contesta en Paperclip).
    func queuePrompt(for item: AttentionItem, base: DecisionPrompt) async -> DecisionPrompt? {
        guard let subjectId = item.subject?.id else { return nil }
        let metadata = item.extras.metadata
        var prompt = base
        switch item.sourceKind {
        case "approval" where metadata?.type == "request_board_approval":
            // Paperclip no la deja contestar en la fila, pero su API sí; se muestra lo que escribió el agente.
            guard let approval: BoardApproval = try? await api.get("api/approvals/\(subjectId)"),
                  approval.status == nil || approval.status == "pending"
            else { return prompt }
            let payload = approval.payload
            prompt.question = payload?.summary ?? prompt.question
            prompt.details = Self.boardDetails(payload)
            prompt.choices = [
                DecisionChoice(label: String(localized: "Approve"), action: .approve(approvalId: subjectId), asks: nil),
                DecisionChoice(label: String(localized: "Reject"), action: .rejectApproval(approvalId: subjectId), asks: nil),
                DecisionChoice(
                    label: String(localized: "Request changes"),
                    action: .requestRevision(approvalId: subjectId),
                    asks: String(localized: "What changes do you want?")
                ),
            ]
        case "join_request":
            guard let companyId = item.extras.companyId,
                  let requests: [Lossy<JoinRequest>] = try? await api.get(
                      "api/companies/\(companyId)/join-requests",
                      query: [URLQueryItem(name: "status", value: "pending_approval")]
                  ),
                  let request = requests.lazy.compactMap(\.value).first(where: { $0.id == subjectId })
            else { return prompt }
            prompt.question = request.summary(fallback: item.subject?.title)
            prompt.choices = [
                DecisionChoice(label: String(localized: "Approve"), action: .queue(.approveJoin(companyId: companyId, requestId: subjectId)), asks: nil),
                DecisionChoice(label: String(localized: "Reject"), action: .queue(.rejectJoin(companyId: companyId, requestId: subjectId)), asks: nil),
            ]
        case "review":
            if metadata?.reviewAttentionState == "stalled" {
                // Las dos opciones que propone Paperclip para una revisión que nadie va a mover.
                prompt.question = String(localized: "Nobody is reviewing it: there’s no reviewer, card or run to move it forward.")
                prompt.choices = [
                    DecisionChoice(
                        label: String(localized: "Request changes"),
                        action: .queue(.requestStalledChanges(issueId: subjectId)),
                        asks: String(localized: "What changes do you want?")
                    ),
                    DecisionChoice(label: String(localized: "Accept"), action: .queue(.acceptStalledReview(issueId: subjectId)), asks: nil),
                ]
                return prompt
            }
            // Solo si la etapa espera a esta persona: Paperclip deja decidir únicamente a quien le toca.
            guard let issue: ReviewIssue = try? await api.get("api/issues/\(subjectId)"),
                  let state = issue.executionState, state.status == "pending",
                  let participant = state.currentParticipant, participant.type == "user",
                  let session: Session = try? await api.get("api/auth/get-session"),
                  let userId = session.user?.id, participant.userId == userId
            else { return prompt }
            prompt.question = state.currentStageType == "approval"
                ? String(localized: "It’s waiting for your approval.")
                : String(localized: "It’s waiting for your review.")
            prompt.choices = [
                DecisionChoice(label: String(localized: "Approve"), action: .queue(.approveReview(issueId: subjectId)), asks: nil),
                DecisionChoice(
                    label: String(localized: "Request changes"),
                    action: .queue(.requestReviewChanges(issueId: subjectId)),
                    asks: String(localized: "What changes do you want?")
                ),
            ]
        case "failed_run":
            prompt.question = metadata?.error ?? metadata?.retryExhaustedReason ?? prompt.question
            if let agentId = metadata?.agentId {
                prompt.choices.append(
                    DecisionChoice(label: String(localized: "Retry"), action: .queue(.retryRun(agentId: agentId, runId: subjectId)), asks: nil)
                )
            }
            if let choice = dismissChoice(item) { prompt.choices.append(choice) }
        case "agent_error_alert":
            prompt.question = metadata?.errorReason ?? prompt.question
            if let choice = dismissChoice(item) { prompt.choices = [choice] }
        case "budget_alert":
            guard let companyId = item.extras.companyId else { return prompt }
            let spent = metadata?.amountObserved.map { Int($0.rounded()) }
            let limit = metadata?.amountLimit.map { Int($0.rounded()) }
            if let spent, let limit {
                prompt.question = String(localized: "Spent \(Self.usd(spent)) of a \(Self.usd(limit)) budget.")
            }
            let hardStop = metadata?.thresholdType == "hard"
            prompt.choices = [
                DecisionChoice(
                    label: hardStop ? String(localized: "Keep paused") : String(localized: "Dismiss"),
                    action: .queue(.keepBudgetPaused(companyId: companyId, incidentId: subjectId)),
                    asks: nil
                ),
                DecisionChoice(
                    label: String(localized: "Raise budget"),
                    action: .queue(.raiseBudget(companyId: companyId, incidentId: subjectId, spentCents: spent)),
                    asks: Self.budgetQuestion(spentCents: spent)
                ),
            ]
        default:
            return nil
        }
        return prompt
    }

    func perform(_ action: QueueAction, text: String?) async throws {
        switch action {
        case let .approveJoin(companyId, requestId):
            try await api.post("api/companies/\(companyId)/join-requests/\(requestId)/approve")
        case let .rejectJoin(companyId, requestId):
            try await api.post("api/companies/\(companyId)/join-requests/\(requestId)/reject")
        case let .approveReview(issueId):
            // Paperclip exige un comentario para aprobar la etapa.
            try await api.patch("api/issues/\(issueId)", ["status": "done", "comment": text ?? String(localized: "Approved.")])
        case let .requestReviewChanges(issueId):
            guard let text else { throw InvalidText(prompt: String(localized: "What changes do you want?")) }
            // Con cualquier estado que no sea `in_review` (y el comentario), la etapa vuelve a quien la entregó.
            try await api.patch("api/issues/\(issueId)", ["status": "in_progress", "comment": text])
        case let .acceptStalledReview(issueId):
            try await api.post("api/issues/\(issueId)/stalled-review-decision", text.map { ["action": "approve", "note": $0] } ?? ["action": "approve"])
        case let .requestStalledChanges(issueId):
            guard let text else { throw InvalidText(prompt: String(localized: "What changes do you want?")) }
            try await api.post("api/issues/\(issueId)/stalled-review-decision", ["action": "request_changes", "note": text])
        case let .retryRun(agentId, runId):
            try await retry(agentId: agentId, runId: runId)
        case let .dismiss(companyId, itemKey):
            try await api.post("api/companies/\(companyId)/inbox-dismissals", ["itemKey": itemKey])
        case let .keepBudgetPaused(companyId, incidentId):
            try await api.post("api/companies/\(companyId)/budget-incidents/\(incidentId)/resolve", ["action": "keep_paused"])
        case let .raiseBudget(companyId, incidentId, spentCents):
            // Paperclip lo guarda en centavos y solo lo acepta si supera lo gastado.
            guard let cents = text.flatMap(Self.cents(fromUSD:)) else {
                throw InvalidText(prompt: String(localized: "That isn’t an amount in USD.") + " " + Self.budgetQuestion(spentCents: spentCents))
            }
            if let spentCents, cents <= spentCents {
                throw InvalidText(prompt: String(localized: "It has to be more than what was already spent.") + " "
                    + Self.budgetQuestion(spentCents: spentCents))
            }
            try await api.post(
                "api/companies/\(companyId)/budget-incidents/\(incidentId)/resolve",
                ["action": "raise_budget_and_resume", "amount": cents]
            )
        }
    }

    /// Como «Retry» en la página: despierta al agente para repetir esa corrida. Paperclip contesta con la corrida
    /// nueva, con una acción de recuperación o con por qué no la repitió.
    private func retry(agentId: String, runId: String) async throws {
        let response: RetryResponse = try await api.post(
            "api/agents/\(agentId)/wakeup",
            ["source": "on_demand", "triggerDetail": "manual", "reason": "retry_failed_run", "failedRunId": runId],
            returning: RetryResponse.self
        )
        let stopped: Set<String> = ["failed", "timed_out", "cancelled", "interrupted"]
        if response.id != nil || response.actionId != nil, !stopped.contains(response.status ?? "") { return }
        throw WakeError(message: response.message.map { String(localized: "Paperclip didn’t retry it: “\($0)”") }
            ?? String(localized: "Paperclip didn’t retry it."))
    }

    private func dismissChoice(_ item: AttentionItem) -> DecisionChoice? {
        guard let companyId = item.extras.companyId, let key = item.extras.dismissalKey else { return nil }
        return DecisionChoice(label: String(localized: "Dismiss"), action: .queue(.dismiss(companyId: companyId, itemKey: key)), asks: nil)
    }

    private static func budgetQuestion(spentCents: Int?) -> String {
        spentCents.map { String(localized: "New budget in USD (more than \(usd($0)) already spent):") }
            ?? String(localized: "New budget in USD:")
    }

    /// La acción recomendada y los riesgos, en Markdown.
    private static func boardDetails(_ payload: BoardApproval.Payload?) -> String? {
        var parts: [String] = []
        if let action = payload?.recommendedAction, !action.isEmpty {
            parts.append(String(localized: "**Recommended action:** \(action)"))
        }
        if let risks = payload?.risks, !risks.isEmpty {
            parts.append(String(localized: "**Risks:**") + "\n" + risks.map { "• \($0)" }.joined(separator: "\n"))
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    /// Centavos de USD, como los muestra Paperclip (`$1,250.50`), sin importar la región de la Mac.
    static func usd(_ cents: Int) -> String {
        (Double(cents) / 100).formatted(.currency(code: "USD").locale(Locale(identifier: "en_US")))
    }

    /// Un monto escrito a mano, en centavos: «250», «$1,250.50», «1.250,50», «300 usd». `nil` si no es un monto
    /// positivo con hasta dos decimales.
    static func cents(fromUSD text: String) -> Int? {
        var digits = text.lowercased()
            .replacingOccurrences(of: "usd", with: "")
            .replacingOccurrences(of: "us$", with: "")
            .replacingOccurrences(of: "$", with: "")
            .filter { !$0.isWhitespace }
        guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == "." || $0 == ",") }) else { return nil }
        // Con los dos signos, el último separa los decimales. Con uno solo, separa decimales si va una vez y le
        // siguen uno o dos dígitos; si no, son miles.
        let lastDot = digits.lastIndex(of: "."), lastComma = digits.lastIndex(of: ",")
        let decimal: Character?
        if let lastDot, let lastComma {
            decimal = lastDot > lastComma ? "." : ","
        } else if let mark = lastDot ?? lastComma {
            let separator = digits[mark]
            let after = digits.distance(from: mark, to: digits.endIndex) - 1
            decimal = digits.count(where: { $0 == separator }) == 1 && (1...2).contains(after) ? separator : nil
        } else {
            decimal = nil
        }
        let thousands: Character? = decimal == "." ? "," : decimal == "," ? "." : nil
        if let thousands { digits.removeAll { $0 == thousands } }
        if decimal == nil { digits.removeAll { $0 == "." || $0 == "," } }
        let parts = digits.split(separator: decimal ?? " ", omittingEmptySubsequences: false)
        guard let whole = parts.first, !whole.isEmpty, let units = Int(whole), parts.count <= 2 else { return nil }
        var fraction = parts.count == 2 ? String(parts[1]) : ""
        guard fraction.count <= 2 else { return nil }
        while fraction.count < 2 { fraction += "0" }
        guard let hundredths = Int(fraction) else { return nil }
        let (scaled, overflow) = units.multipliedReportingOverflow(by: 100)
        guard !overflow, scaled + hundredths > 0, scaled + hundredths <= Int(Int32.max) else { return nil }
        return scaled + hundredths
    }

    // MARK: - Lo que se lee de la API

    private struct BoardApproval: Decodable {
        let status: String?
        let payload: Payload?

        struct Payload: Decodable {
            let summary: String?
            let recommendedAction: String?
            let risks: [String]?

            private enum CodingKeys: String, CodingKey { case summary, recommendedAction, risks }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                summary = try? container.decodeIfPresent(String.self, forKey: .summary)
                recommendedAction = try? container.decodeIfPresent(String.self, forKey: .recommendedAction)
                // Los riesgos suelen venir como lista; un agente también puede escribirlos como un solo texto.
                if let list = try? container.decodeIfPresent([String].self, forKey: .risks) {
                    risks = list
                } else if let single = try? container.decodeIfPresent(String.self, forKey: .risks) {
                    risks = [single]
                } else {
                    risks = nil
                }
            }
        }
    }

    private struct JoinRequest: Decodable {
        let id: String
        let requestType: String?
        let agentName: String?
        let adapterType: String?
        let requestEmailSnapshot: String?
        let requesterUser: Person?
        let invite: Invite?

        struct Person: Decodable {
            let name: String?
            let email: String?
        }

        struct Invite: Decodable {
            let humanRole: String?
        }

        /// Quién pide y qué acceso.
        func summary(fallback: String?) -> String {
            if requestType == "agent" {
                let name = agentName ?? fallback ?? String(localized: "An agent")
                return adapterType.map { String(localized: "The agent \(name) asks to join the company (adapter \($0)).") }
                    ?? String(localized: "The agent \(name) asks to join the company.")
            }
            let who = [requesterUser?.name, requesterUser?.email ?? requestEmailSnapshot].compactMap { $0 }
                .joined(separator: " · ")
            let person = who.isEmpty ? fallback ?? String(localized: "Someone") : who
            guard let role = invite?.humanRole else { return String(localized: "\(person) asks to join the company.") }
            return String(localized: "\(person) asks to join the company as \(Self.roleName(role)).")
        }

        private static func roleName(_ role: String) -> String {
            switch role {
            case "owner": String(localized: "owner")
            case "admin": String(localized: "admin")
            case "operator": String(localized: "operator")
            case "viewer": String(localized: "viewer")
            default: role
            }
        }
    }

    private struct ReviewIssue: Decodable {
        let executionState: ExecutionState?

        struct ExecutionState: Decodable {
            let status: String?
            let currentStageType: String?
            let currentParticipant: Participant?
        }

        struct Participant: Decodable {
            let type: String?
            let userId: String?
        }
    }

    private struct Session: Decodable {
        let user: User?

        struct User: Decodable {
            let id: String?
        }
    }

    /// La corrida nueva (`id`), una acción de recuperación (`actionId`) o, si no la repitió, `message`.
    private struct RetryResponse: Decodable {
        let id: String?
        let actionId: String?
        let status: String?
        let message: String?

        private enum CodingKeys: String, CodingKey { case id, actionId, status, message }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try? container.decodeIfPresent(String.self, forKey: .id)
            actionId = try? container.decodeIfPresent(String.self, forKey: .actionId)
            status = try? container.decodeIfPresent(String.self, forKey: .status)
            message = try? container.decodeIfPresent(String.self, forKey: .message)
        }
    }
}
