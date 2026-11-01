import Foundation
import os
import SwiftUI

// Despertar automático del agente revisor que Paperclip se salta.
//
// Es un bug de Paperclip 2026.1023.0 (https://github.com/paperclipai/paperclip/issues/18315): cuando un agente
// pasa a revisión una tarea con etapa de revisión desde su propia corrida, Paperclip descarta el despertar
// del agente revisor (`skipped`, «The previous execution has not released its environment lease») y nada lo
// reintenta. La tarea queda en revisión sin que nadie la revise.
//
// Todo vive en este archivo para quitarlo de una vez cuando Paperclip publique el arreglo (VIN-242). Lo demás
// son enganches: el ajuste (`Preferences.wakeStrandedReviewers`), la llamada en cada revisión de Decisions
// (`DecisionsMonitor`), la sección de Ajustes (`ReviewWakeSection` en la pestaña Paperclip) y los parámetros
// de `DecisionResolver.wake`.

/// Revisa en cada vuelta las tareas en revisión de una company y despierta, una sola vez por traspaso, al
/// agente revisor que se quedó dormido. Si lo despierta, no avisa nada. Si Paperclip lo salta o falla, devuelve
/// la tarjeta de «Tarea trabada» con su botón «Despertar a …», que el monitor suma a lo de Decisions para que
/// llegue a la Mac y a Telegram como cualquier otra.
@MainActor
final class ReviewWaker {
    /// Lo que se espera desde el traspaso antes de despertar: un despertar de Paperclip que sí llega tarda
    /// segundos, y así no se le adelanta.
    static let margin: TimeInterval = 2 * 60
    /// El `reason` de estos despertares, para distinguirlos de los del botón en el historial de Paperclip.
    static let wakeReason = "dispatch_review_wake_recovery"
    /// Lo intentado, por traspaso. Sobrevive a un reinicio para no gastar corridas en bucle.
    private static let attemptsKey = "reviewWakeAttempts"
    /// Cuánto se recuerda un intento.
    private static let keepAttempts: TimeInterval = 30 * 24 * 60 * 60
    /// Despertares que todavía pueden llevar al agente a correr en la tarea.
    private static let pendingWakeStatuses: Set<String> = ["queued", "claimed", "deferred_issue_execution"]
    /// Despertares que ya terminaron en una corrida del agente.
    private static let ranWakeStatuses: Set<String> = ["completed", "coalesced"]
    /// Agentes que Paperclip no deja correr.
    private static let unavailableAgentStatuses: Set<String> = ["paused", "terminated", "pending_approval"]

    /// Un intento de despertar, guardado en la Mac.
    struct Attempt: Codable, Equatable {
        enum Outcome: String, Codable {
            /// Se guarda antes de pedirlo: si la app se cierra a mitad, no se vuelve a intentar y, si el revisor
            /// no se puso en camino, sale la tarjeta como si hubiera fallado.
            case requested
            /// Paperclip lo aceptó, o ya no hacía falta.
            case done
            /// No hizo falta: el revisor ya había corrido en la tarea después del traspaso.
            case notNeeded
            /// Paperclip lo saltó o falló: va la tarjeta con el botón.
            case failed
            /// La tarjeta ya no hace falta: el agente se puso en camino (p. ej. con el botón).
            case recovered
        }

        var at: Date
        var outcome: Outcome
        var companyId: String
        var issueId: String
        var agentId: String
        var agentName: String?
        var identifier: String?
        var title: String?

        /// Si va la tarjeta de «Tarea trabada»: falló, o la app se cerró mientras lo pedía.
        var showsCard: Bool { outcome == .failed || outcome == .requested }
    }

    private let api: PaperclipAPI
    private let resolver: DecisionResolver
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "PaperclipDispatch", category: "review-wake")
    private var attempts: [String: Attempt]
    /// Lo último que se decidió de cada traspaso, para anotarlo en el registro solo cuando cambia.
    private var lastDecision: [String: String] = [:]
    /// La etapa de cada tarea en revisión, con el `updatedAt` con que se leyó: la lista de tareas no la trae, y
    /// la tarea se vuelve a leer solo si cambió.
    private var handoffs: [String: (updatedAt: String?, handoff: Handoff?)] = [:]

    init(api: PaperclipAPI, resolver: DecisionResolver) {
        self.api = api
        self.resolver = resolver
        attempts = UserDefaults.standard.data(forKey: Self.attemptsKey)
            .flatMap { try? JSONDecoder().decode([String: Attempt].self, from: $0) } ?? [:]
    }

    /// Una company en una vuelta del monitor. `decisions`: lo que ya trae Decisions, para no duplicar la tarjeta
    /// de una tarea que ya está ahí con el mismo despertar. Devuelve las tarjetas de los despertares que fallaron.
    func check(_ company: PaperclipCompany, decisions: [AttentionItem]) async -> [AttentionItem] {
        // Una lectura por company: las tareas en revisión. Lo demás se lee solo de las candidatas.
        guard let list: [Lossy<ReviewIssue>] = try? await api.get(
            "api/companies/\(company.id)/issues",
            query: [URLQueryItem(name: "status", value: "in_review")]
        ) else { return [] }
        let now = Date()
        var cards: [AttentionItem] = []
        let issues = list.compactMap(\.value).filter { $0.status == "in_review" && $0.assigneeAgentId != nil }
        let ids = Set(issues.map(\.id))
        handoffs = handoffs.filter { ids.contains($0.key) }
        lastDecision = lastDecision.filter { ids.contains(String($0.key.prefix { $0 != ":" })) }
        for summary in issues {
            // Lo que acaba de cambiar espera el margen sin leer nada más, salvo que ya tenga su tarjeta.
            let hasCard = attempts.values.contains { $0.issueId == summary.id && $0.showsCard }
            if !hasCard, Self.recent(summary, now: now) {
                note(summary.id, summary, "waiting for the margin")
                continue
            }
            guard let (issue, handoff) = await handoff(for: summary) else { continue }
            if let attempt = attempts[handoff.key] {
                guard attempt.showsCard else { continue }
                if let card = await failedCard(attempt, key: handoff.key, company: company, decisions: decisions) {
                    cards.append(card)
                }
                continue
            }
            // La tarjeta era de un traspaso anterior: este también espera su margen.
            if Self.recent(summary, now: now) {
                note(summary.id, summary, "waiting for the margin")
                continue
            }
            await consider(issue, handoff: handoff, company: company, now: now)
            if let attempt = attempts[handoff.key], attempt.showsCard,
               let card = await failedCard(attempt, key: handoff.key, company: company, decisions: decisions) {
                cards.append(card)
            }
        }
        prune(now: now)
        return cards
    }

    /// Si la tarea cambió hace menos que el margen.
    private static func recent(_ summary: ReviewIssue, now: Date) -> Bool {
        guard let since = summary.updatedAt.flatMap(date) else { return false }
        return now.timeIntervalSince(since) < margin
    }

    /// La etapa pendiente de una tarea de la lista: la guardada si la tarea no cambió; si no, la lee.
    private func handoff(for summary: ReviewIssue) async -> (ReviewIssue, Handoff)? {
        if let cached = handoffs[summary.id], cached.updatedAt == summary.updatedAt {
            return cached.handoff.map { (summary, $0) }
        }
        guard let issue: ReviewIssue = try? await api.get("api/issues/\(summary.id)") else { return nil }
        handoffs[summary.id] = (summary.updatedAt, issue.handoff)
        if issue.handoff == nil { note(summary.id, summary, "no pending review stage for its agent") }
        return issue.handoff.map { (issue, $0) }
    }

    /// Un traspaso sin intento: lo despierta si de verdad se quedó dormido.
    private func consider(_ issue: ReviewIssue, handoff: Handoff, company: PaperclipCompany, now: Date) async {
        let target = WakeTarget(agentId: handoff.agentId, issueId: issue.id, issueIdentifier: issue.identifier)
        let agent: ReviewAgent
        do {
            agent = try await api.get("api/agents/\(handoff.agentId)")
        } catch {
            return note(handoff.key, issue, "couldn't read the agent")
        }
        if let status = agent.status, Self.unavailableAgentStatuses.contains(status) {
            return note(handoff.key, issue, "agent is \(status)" + (agent.pauseReason.map { " (\($0))" } ?? ""))
        }
        if let budget = agent.budgetMonthlyCents, budget > 0, (agent.spentMonthlyCents ?? 0) >= budget {
            return note(handoff.key, issue, "agent is out of budget")
        }
        guard let progress = await resolver.wakeProgress(target) else {
            return note(handoff.key, issue, "couldn't read live runs")
        }
        if case .onTheWay = progress { return note(handoff.key, issue, "agent has a queued or running run") }
        guard let mine = await wakes(of: handoff.agentId, on: issue.id) else {
            return note(handoff.key, issue, "couldn't read wake diagnostics")
        }
        if mine.contains(where: { Self.pendingWakeStatuses.contains($0.status ?? "") }) {
            return note(handoff.key, issue, "agent has a pending wake-up")
        }
        // Paperclip los da del más nuevo al más viejo. Si lo último fue una corrida, el revisor ya pasó por la
        // tarea después del traspaso (p. ej. espera una tarjeta de la persona): no se quedó dormido, y para
        // este traspaso no se vuelve a mirar.
        if let latest = mine.first, Self.ranWakeStatuses.contains(latest.status ?? "") {
            record(Attempt(
                at: now, outcome: .notNeeded, companyId: company.id, issueId: issue.id, agentId: handoff.agentId,
                agentName: nil, identifier: issue.identifier, title: issue.title
            ), for: handoff.key)
            return note(handoff.key, issue, "agent already ran after the handoff")
        }

        var attempt = Attempt(
            at: now, outcome: .requested, companyId: company.id, issueId: issue.id, agentId: handoff.agentId,
            agentName: agent.name.flatMap { $0.isEmpty ? nil : $0 }, identifier: issue.identifier, title: issue.title
        )
        record(attempt, for: handoff.key)
        let outcome = await resolver.wake(
            target,
            reason: Self.wakeReason,
            triggerDetail: "system",
            idempotencyKey: "paperclip-dispatch:review-wake:\(handoff.key)"
        )
        attempt.outcome = switch outcome {
        case .accepted, .alreadyRunning, .notStuck: .done
        case .skipped, .failed: .failed
        }
        record(attempt, for: handoff.key)
        note(handoff.key, issue, "woke the reviewer: \(outcome)")
    }

    /// La tarjeta de un despertar que falló, mientras el revisor siga sin ponerse en camino.
    private func failedCard(
        _ attempt: Attempt,
        key: String,
        company: PaperclipCompany,
        decisions: [AttentionItem]
    ) async -> AttentionItem? {
        let target = WakeTarget(agentId: attempt.agentId, issueId: attempt.issueId, issueIdentifier: attempt.identifier)
        // En camino ahora, o un despertar suyo pedido después del intento que ya corrió o va a correr (p. ej. el
        // botón de la tarjeta, con una corrida que terminó antes de esta vuelta).
        var onItsWay = false
        if case .onTheWay? = await resolver.wakeProgress(target) {
            onItsWay = true
        } else if let mine = await wakes(of: attempt.agentId, on: attempt.issueId) {
            onItsWay = mine.contains { event in
                guard let requested = event.requestedAt.flatMap(Self.date), requested > attempt.at else { return false }
                return Self.pendingWakeStatuses.union(Self.ranWakeStatuses).contains(event.status ?? "")
            }
        }
        if onItsWay {
            var recovered = attempt
            recovered.outcome = .recovered
            record(recovered, for: key)
            log.notice("\(attempt.identifier ?? attempt.issueId, privacy: .public): reviewer is on its way, card dropped")
            return nil
        }
        // Decisions ya la muestra con el mismo despertar (p. ej. porque bloquea a otra tarea).
        if decisions.contains(where: { $0.wakeTarget?.issueId == attempt.issueId && $0.wakeTarget?.agentId == attempt.agentId }) {
            return nil
        }
        return Self.card(for: attempt, key: key, issuePrefix: company.issuePrefix)
    }

    /// La tarjeta de «Tarea trabada» con el botón «Despertar a …», con la forma de las de Decisions
    /// (`blocker_attention` con `nudge`) para que la Mac y Telegram la muestren igual.
    static func card(for attempt: Attempt, key: String, issuePrefix: String?) -> AttentionItem? {
        /// En JSON, un valor que falta va como `null`.
        func value(_ text: String?) -> Any { text.map { $0 as Any } ?? NSNull() }
        var href: Any = NSNull()
        if let issuePrefix, let identifier = attempt.identifier { href = "/\(issuePrefix)/issues/\(identifier)" }
        let agent = attempt.agentName ?? String(localized: "The reviewing agent")
        let json: [String: Any] = [
            "id": "dispatch-review-wake:\(key)",
            "sourceKind": "blocker_attention",
            "subject": [
                "kind": "issue",
                "id": attempt.issueId,
                "identifier": value(attempt.identifier),
                "title": value(attempt.title),
                "href": href,
                "metadata": ["assigneeAgentId": attempt.agentId],
            ],
            "relatedIssue": [
                "kind": "issue",
                "id": attempt.issueId,
                "identifier": value(attempt.identifier),
                "href": href,
            ],
            "originAgentName": value(attempt.agentName),
            "whyNow": String(localized: "In review, but Paperclip didn’t wake up the reviewing agent."),
            "detail": [
                "promptExcerpt": String(
                    localized: "In review, but Paperclip didn’t wake up \(agent) to review it, and the app’s automatic wake-up didn’t work either."
                ),
            ],
            "decisionVerbs": [["id": "nudge"]],
            "inlineResolvable": false,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: json) else { return nil }
        return try? JSONDecoder().decode(AttentionItem.self, from: data)
    }

    /// Los despertares de un agente en una tarea, del más nuevo al más viejo. Sin el id del agente (Paperclip lo
    /// oculta a quien no ve la company entera) cuentan todos: así, ante la duda, no se despierta a nadie.
    private func wakes(of agentId: String, on issueId: String) async -> [WakeEvent]? {
        guard let diagnostics: WakeDiagnostics = try? await api.get("api/issues/\(issueId)/diagnostics/wakes")
        else { return nil }
        return diagnostics.events.compactMap(\.value)
            .filter { $0.kind == "wake_request" && ($0.agentId == nil || $0.agentId == agentId) }
    }

    private func record(_ attempt: Attempt, for key: String) {
        attempts[key] = attempt
        save()
    }

    private func prune(now: Date) {
        let kept = attempts.filter { now.timeIntervalSince($0.value.at) < Self.keepAttempts }
        guard kept.count != attempts.count else { return }
        attempts = kept
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(attempts) else { return }
        UserDefaults.standard.set(data, forKey: Self.attemptsKey)
    }

    /// Lo que se decidió de un traspaso, en el registro de macOS (`log show`), solo cuando cambia.
    private func note(_ key: String, _ issue: ReviewIssue, _ decision: String) {
        guard lastDecision[key] != decision else { return }
        lastDecision[key] = decision
        log.notice("\(issue.identifier ?? issue.id, privacy: .public): \(decision, privacy: .public)")
    }

    private static func date(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    // MARK: - Lo que se lee de la API

    /// Un traspaso: la tarea, la etapa, la vuelta de revisión y el agente. Un intento por cada uno.
    struct Handoff {
        let key: String
        let agentId: String
    }

    struct ReviewIssue: Decodable {
        let id: String
        let identifier: String?
        let title: String?
        let status: String?
        let assigneeAgentId: String?
        let updatedAt: String?
        let executionState: ExecutionState?

        /// La etapa pendiente a cargo de un agente, si la tarea sigue a su nombre.
        var handoff: Handoff? {
            guard status == "in_review", let state = executionState, state.status == "pending",
                  let participant = state.currentParticipant, participant.type == "agent",
                  let agentId = participant.agentId, assigneeAgentId == agentId
            else { return nil }
            let key = [id, state.currentStageId ?? "", String(state.changesRequestedCount ?? 0), agentId]
                .joined(separator: ":")
            return Handoff(key: key, agentId: agentId)
        }
    }

    struct ExecutionState: Decodable {
        let status: String?
        let currentStageId: String?
        let currentParticipant: Participant?
        let changesRequestedCount: Int?
    }

    struct Participant: Decodable {
        let type: String?
        let agentId: String?
    }

    private struct ReviewAgent: Decodable {
        let name: String?
        let status: String?
        let pauseReason: String?
        let budgetMonthlyCents: Int?
        let spentMonthlyCents: Int?
    }

    private struct WakeDiagnostics: Decodable {
        let events: [Lossy<WakeEvent>]
    }

    private struct WakeEvent: Decodable {
        let kind: String?
        let agentId: String?
        let status: String?
        let requestedAt: String?
    }
}

/// En la pestaña Paperclip de Ajustes: el interruptor con su explicación y el enlace al bug.
struct ReviewWakeSection: View {
    @Bindable var preferences: Preferences

    private static let issueURL = URL(string: "https://github.com/paperclipai/paperclip/issues/18315")!

    var body: some View {
        Section {
            Toggle(isOn: $preferences.wakeStrandedReviewers) {
                Text("Wake up reviewers Paperclip forgets")
                Text("When an agent hands a task over for review, Paperclip sometimes doesn’t wake up the reviewing agent, and the task sits in review with no one on it. If \(Int(ReviewWaker.margin / 60)) minutes go by and the reviewer still isn’t working on it, the app wakes it up, once.")
            }
        } header: {
            Text("Reviews")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("It’s on by default because it’s a known Paperclip bug: without it, those tasks wait until someone notices. It works quietly; only if the wake-up fails do you get the stuck-task notification with its button. It will go away once Paperclip fixes the bug.")
                    .settingsFootnote()
                Link("Paperclip issue #18315 on GitHub", destination: Self.issueURL)
                    .font(.footnote)
            }
        }
    }
}
