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
//
// Lo que se lee de Paperclip se lee estricto, con lectores propios (no con los de la parte C, que descartan lo
// que no entienden): si una respuesta no se puede leer bien, no se sabe si el revisor va en camino, y no se
// despierta a nadie. Pasado el margen llega la tarjeta de la tarea trabada, que dice que no se pudo comprobar.

/// Revisa en cada vuelta las tareas en revisión de una company y despierta, una sola vez por traspaso, al
/// agente revisor que se quedó dormido. Si lo despierta, no avisa nada. Si Paperclip lo salta o falla, o si
/// lo que contesta Paperclip no se puede leer, devuelve la tarjeta de «Tarea trabada», que el monitor suma a
/// lo de Decisions para que llegue a la Mac y a Telegram como cualquier otra.
@MainActor
final class ReviewWaker {
    /// Lo que se espera desde el traspaso antes de despertar: un despertar de Paperclip que sí llega tarda
    /// segundos, y así no se le adelanta.
    static let margin: TimeInterval = 2 * 60
    /// El `reason` de estos despertares, para distinguirlos de los del botón en el historial de Paperclip.
    static let wakeReason = "dispatch_review_wake_recovery"
    /// Lo intentado, por traspaso. Sobrevive a un reinicio para no gastar corridas en bucle.
    private static let attemptsKey = "reviewWakeAttempts"
    /// Las tarjetas de «no se pudo comprobar», por traspaso: una sola vez cada una, también tras un reinicio.
    private static let unverifiedKey = "reviewWakeUnverified"
    /// Cuánto se recuerda un intento.
    private static let keepAttempts: TimeInterval = 30 * 24 * 60 * 60
    /// Las veces seguidas que tiene que fallar una lectura por red o por un 5xx antes de mandar la tarjeta.
    private static let transientFailuresForCard = 2

    // Los valores que conoce la app, según Paperclip 2026.1023.0. Otro cualquiera es una respuesta cambiada.
    /// `diagnostics/wakes`: `kind` de cada evento.
    nonisolated private static let wakeEventKinds: Set<String> = ["wake_request", "activity"]
    /// `diagnostics/wakes`: `status` de un despertar (Paperclip manda `other` para uno que no conoce).
    nonisolated private static let wakeStatuses: Set<String> = [
        "queued", "claimed", "deferred_issue_execution", "completed", "coalesced", "skipped", "failed", "cancelled",
    ]
    /// Despertares que todavía pueden llevar al agente a correr en la tarea.
    nonisolated private static let pendingWakeStatuses: Set<String> = ["queued", "claimed", "deferred_issue_execution"]
    /// Despertares que ya terminaron en una corrida del agente.
    nonisolated private static let ranWakeStatuses: Set<String> = ["completed", "coalesced"]
    /// `live-runs`: solo trae corridas en cola o en curso.
    nonisolated private static let liveRunStatuses: Set<String> = ["queued", "running"]
    /// `executionState.status`.
    nonisolated private static let stageStatuses: Set<String> = ["idle", "pending", "changes_requested", "completed"]
    /// `executionState.currentParticipant.type`.
    nonisolated private static let participantTypes: Set<String> = ["agent", "user"]
    /// `status` de un agente.
    nonisolated private static let agentStatuses: Set<String> = [
        "active", "paused", "idle", "running", "error", "pending_approval", "terminated",
    ]
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

    /// Un traspaso que no se pudo comprobar porque Paperclip contestó algo que no se puede leer. Su tarjeta sale
    /// una vez: cuando se vuelve a poder leer, se retira y no vuelve.
    struct Unverified: Codable, Equatable {
        var at: Date
        var showing: Bool
        var companyId: String
        var issueId: String
        /// Solo si se leyó bien al participante de la etapa: sin él, la tarjeta no lleva el botón.
        var agentId: String?
        var agentName: String?
        var identifier: String?
        var title: String?
    }

    /// Lo que no se pudo leer de Paperclip: la ruta y qué faltaba o no se entendía.
    struct ReadProblem: Error {
        let path: String
        let detail: String
        /// Red o 5xx: puede ser pasajero, así que la tarjeta espera a la revisión siguiente.
        let transient: Bool
    }

    private let api: PaperclipAPI
    private let resolver: DecisionResolver
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "PaperclipDispatch", category: "review-wake")
    private var attempts: [String: Attempt]
    private var unverified: [String: Unverified]
    /// Las lecturas seguidas que fallaron por red o por un 5xx, por traspaso.
    private var transientFailures: [String: Int] = [:]
    /// Lo último que se decidió de cada traspaso, para anotarlo en el registro solo cuando cambia.
    private var lastDecision: [String: String] = [:]
    /// Lo último que falló al leer la lista de cada company, por lo mismo.
    private var listProblem: [String: String] = [:]
    /// Cuándo vio la app cada tarea, para medir el margen si la lista no trae un `updatedAt` legible.
    private var firstSeen: [String: Date] = [:]
    /// La etapa de cada tarea en revisión, con el `updatedAt` con que se leyó: la lista de tareas no la trae, y
    /// la tarea se vuelve a leer solo si cambió.
    private var stages: [String: (updatedAt: String?, reading: StageReading)] = [:]

    init(api: PaperclipAPI, resolver: DecisionResolver) {
        self.api = api
        self.resolver = resolver
        attempts = UserDefaults.standard.data(forKey: Self.attemptsKey)
            .flatMap { try? JSONDecoder().decode([String: Attempt].self, from: $0) } ?? [:]
        unverified = UserDefaults.standard.data(forKey: Self.unverifiedKey)
            .flatMap { try? JSONDecoder().decode([String: Unverified].self, from: $0) } ?? [:]
    }

    /// Una company en una vuelta del monitor. `decisions`: lo que ya trae Decisions, para no duplicar la tarjeta
    /// de una tarea que ya está ahí. Devuelve las tarjetas de los despertares que fallaron y de los traspasos
    /// que no se pudieron comprobar.
    func check(_ company: PaperclipCompany, decisions: [AttentionItem]) async -> [AttentionItem] {
        // Una lectura por company: las tareas en revisión. Lo demás se lee solo de las candidatas.
        let list: [Lossy<ReviewIssue>]
        do {
            list = try await read("api/companies/\(company.id)/issues", query: [URLQueryItem(name: "status", value: "in_review")])
        } catch {
            // Sin la lista no se sabe qué tareas mirar: no hay tarjeta posible, solo la línea en el registro.
            noteList(company, "couldn't read \(error.path): \(error.detail)")
            return []
        }
        let read = list.compactMap(\.value)
        noteList(company, Self.listProblem(read, unreadable: list.count - read.count))
        let now = Date()
        var cards: [AttentionItem] = []
        // Lo que no vino se da por bueno: la lista ya es de las tareas en revisión, y la tarea se lee entera.
        let issues = read.filter { ($0.status ?? "in_review") == "in_review" && ($0.assigneeAgentId != nil || !$0.assigneeKnown) }
        let ids = Set(issues.map(\.id))
        func ofListed(_ key: String) -> Bool { ids.contains(String(key.prefix { $0 != ":" })) }
        stages = stages.filter { ids.contains($0.key) }
        firstSeen = firstSeen.filter { ids.contains($0.key) }
        lastDecision = lastDecision.filter { ofListed($0.key) }
        transientFailures = transientFailures.filter { ofListed($0.key) }
        // Una tarjeta con partes sin leer (`?`) no distingue un traspaso de otro: cuando la tarea sale de
        // revisión se olvida, para que el traspaso siguiente tenga la suya.
        let guesses = unverified.filter { !ids.contains($0.value.issueId) && $0.key.contains(":?") }
        if !guesses.isEmpty {
            unverified = unverified.filter { guesses[$0.key] == nil }
            saveUnverified()
        }
        for summary in issues {
            // Lo que acaba de cambiar espera el margen sin leer nada más, salvo que ya tenga su tarjeta.
            let hasCard = attempts.values.contains { $0.issueId == summary.id && $0.showsCard }
                || unverified.values.contains { $0.issueId == summary.id && $0.showing }
            if !hasCard, recent(summary, now: now) {
                note(summary.id, summary, "waiting for the margin")
                continue
            }
            let handoff: Handoff
            switch await stage(of: summary) {
            case let .none(reason):
                note(summary.id, summary, reason)
                retireUnverified(issueId: summary.id, except: nil)
                continue
            case let .unreadable(partial, problem):
                // Sin saber qué traspaso es, sigue la tarjeta del despertar que falló, si la hay.
                if let (key, attempt) = attempts.filter({ $0.value.issueId == summary.id && $0.value.showsCard })
                    .max(by: { $0.value.at < $1.value.at }) {
                    note(key, summary, "couldn't read \(problem.path): \(problem.detail)")
                    if let card = await failedCard(attempt, key: key, company: company, decisions: decisions) { cards.append(card) }
                    continue
                }
                if let card = await unverifiedCard(partial, problem, summary: summary, company: company, decisions: decisions, now: now) {
                    cards.append(card)
                }
                continue
            case let .agent(found):
                handoff = found
            }
            // Una tarjeta de otro traspaso de esta tarea ya no vale.
            retireUnverified(issueId: summary.id, except: handoff.key)
            if let attempt = attempts[handoff.key] {
                guard attempt.showsCard else { continue }
                if let card = await failedCard(attempt, key: handoff.key, company: company, decisions: decisions) {
                    cards.append(card)
                }
                continue
            }
            // La tarjeta era de un traspaso anterior: este también espera su margen.
            if unverified[handoff.key]?.showing != true, recent(summary, now: now) {
                note(summary.id, summary, "waiting for the margin")
                continue
            }
            if let problem = await consider(handoff, summary: summary, company: company, now: now) {
                let partial = PartialHandoff(key: handoff.key, agentId: handoff.agentId)
                if let card = await unverifiedCard(partial, problem, summary: summary, company: company, decisions: decisions, now: now) {
                    cards.append(card)
                }
                continue
            }
            transientFailures[handoff.key] = nil
            retireUnverified(issueId: summary.id, except: nil)
            if let attempt = attempts[handoff.key], attempt.showsCard,
               let card = await failedCard(attempt, key: handoff.key, company: company, decisions: decisions) {
                cards.append(card)
            }
        }
        prune(now: now)
        return cards
    }

    /// Si la tarea cambió hace menos que el margen. Sin un `updatedAt` legible, el margen cuenta desde que la app
    /// la vio en la lista.
    private func recent(_ summary: ReviewIssue, now: Date) -> Bool {
        if let since = summary.updatedAt.flatMap(Self.date) { return now.timeIntervalSince(since) < Self.margin }
        let seen = firstSeen[summary.id] ?? now
        firstSeen[summary.id] = seen
        return now.timeIntervalSince(seen) < Self.margin
    }

    /// Lo que no se pudo leer de la lista, para el registro. `nil`: nada.
    private static func listProblem(_ issues: [ReviewIssue], unreadable: Int) -> String? {
        var missing: [String] = []
        if issues.contains(where: { $0.status == nil }) { missing.append("status") }
        if issues.contains(where: { !$0.assigneeKnown }) { missing.append("assigneeAgentId") }
        if issues.contains(where: { $0.updatedAt.flatMap(date) == nil }) { missing.append("updatedAt") }
        var parts: [String] = []
        if unreadable > 0 { parts.append("couldn't read \(unreadable) of the in-review issues") }
        if !missing.isEmpty { parts.append("in-review issues without a readable " + missing.joined(separator: ", ")) }
        return parts.isEmpty ? nil : parts.joined(separator: "; ")
    }

    /// La etapa pendiente de una tarea de la lista: la guardada si la tarea no cambió; si no, la lee. Una lectura
    /// que no se pudo hacer no se guarda: se vuelve a intentar en la vuelta siguiente, para retirar la tarjeta
    /// en cuanto Paperclip conteste bien.
    private func stage(of summary: ReviewIssue) async -> StageReading {
        if let cached = stages[summary.id], cached.updatedAt == summary.updatedAt { return cached.reading }
        let reading: StageReading
        let path = "api/issues/\(summary.id)"
        do {
            let issue: IssueDetail = try await read(path)
            reading = issue.reading(path: path)
            transientFailures[Handoff.key(summary.id, nil, nil, nil)] = nil
        } catch {
            reading = .unreadable(PartialHandoff(key: Handoff.key(summary.id, nil, nil, nil), agentId: nil), error)
        }
        if case .unreadable = reading { return reading }
        stages[summary.id] = (summary.updatedAt, reading)
        return reading
    }

    /// Un traspaso sin intento: lo despierta si de verdad se quedó dormido. Devuelve lo que no pudo leer, si
    /// algo no se pudo leer: entonces no despierta a nadie.
    private func consider(_ handoff: Handoff, summary: ReviewIssue, company: PaperclipCompany, now: Date) async -> ReadProblem? {
        let target = WakeTarget(agentId: handoff.agentId, issueId: summary.id, issueIdentifier: summary.identifier)
        let agent: ReviewAgent
        do {
            agent = try await read("api/agents/\(handoff.agentId)")
        } catch {
            return error
        }
        if Self.unavailableAgentStatuses.contains(agent.status) {
            note(handoff.key, summary, "agent is \(agent.status)" + (agent.pauseReason.map { " (\($0))" } ?? ""))
            return nil
        }
        if let budget = agent.budgetMonthlyCents, budget > 0, (agent.spentMonthlyCents ?? 0) >= budget {
            note(handoff.key, summary, "agent is out of budget")
            return nil
        }
        let runs: [LiveRun]
        do {
            runs = try await liveRuns(on: summary.id)
        } catch {
            return error
        }
        if runs.contains(where: { $0.agentId == handoff.agentId }) {
            note(handoff.key, summary, "agent has a queued or running run")
            return nil
        }
        let mine: [WakeEvent]
        do {
            mine = try await wakes(of: handoff.agentId, on: summary.id)
        } catch {
            return error
        }
        // Solo cuenta lo del revisor: un despertar pendiente de otro agente (p. ej. el del ingeniero, que quedó
        // huérfano al pasar la tarea a revisión) no lo lleva a la tarea.
        if mine.contains(where: { Self.pendingWakeStatuses.contains($0.status ?? "") }) {
            note(handoff.key, summary, "agent has a pending wake-up")
            return nil
        }
        // Paperclip los da del más nuevo al más viejo. Si lo último fue una corrida, el revisor ya pasó por la
        // tarea después del traspaso (p. ej. espera una tarjeta de la persona): no se quedó dormido, y para
        // este traspaso no se vuelve a mirar.
        if let latest = mine.first, Self.ranWakeStatuses.contains(latest.status ?? "") {
            record(Attempt(
                at: now, outcome: .notNeeded, companyId: company.id, issueId: summary.id, agentId: handoff.agentId,
                agentName: nil, identifier: summary.identifier, title: summary.title
            ), for: handoff.key)
            note(handoff.key, summary, "agent already ran after the handoff")
            return nil
        }

        var attempt = Attempt(
            at: now, outcome: .requested, companyId: company.id, issueId: summary.id, agentId: handoff.agentId,
            agentName: agent.name.flatMap { $0.isEmpty ? nil : $0 }, identifier: summary.identifier, title: summary.title
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
        note(handoff.key, summary, "woke the reviewer: \(outcome)")
        return nil
    }

    /// La tarjeta de un despertar que falló, mientras el revisor siga sin ponerse en camino. Si no se puede leer
    /// si va en camino, la tarjeta sigue.
    private func failedCard(
        _ attempt: Attempt,
        key: String,
        company: PaperclipCompany,
        decisions: [AttentionItem]
    ) async -> AttentionItem? {
        // En camino ahora, o un despertar suyo pedido después del intento que ya corrió o va a correr (p. ej. el
        // botón de la tarjeta, con una corrida que terminó antes de esta vuelta).
        var onItsWay = false
        do {
            if try await liveRuns(on: attempt.issueId).contains(where: { $0.agentId == attempt.agentId }) {
                onItsWay = true
            } else {
                onItsWay = try await wakes(of: attempt.agentId, on: attempt.issueId).contains { event in
                    guard let requested = event.requestedAt.flatMap(Self.date), requested > attempt.at else { return false }
                    return Self.pendingWakeStatuses.union(Self.ranWakeStatuses).contains(event.status ?? "")
                }
            }
        } catch {
            note(key, attempt.identifier ?? attempt.issueId, "couldn't read \(error.path): \(error.detail); the card stays")
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
        return Self.failedItem(attempt, key: key, issuePrefix: company.issuePrefix)
    }

    /// La tarjeta de un despertar que falló, con el botón «Despertar a …».
    static func failedItem(_ attempt: Attempt, key: String, issuePrefix: String?) -> AttentionItem? {
        card(
            id: "dispatch-review-wake:\(key)",
            issueId: attempt.issueId,
            identifier: attempt.identifier,
            title: attempt.title,
            agentId: attempt.agentId,
            agentName: attempt.agentName,
            issuePrefix: issuePrefix,
            whyNow: String(localized: "In review, but Paperclip didn’t wake up the reviewing agent."),
            text: attempt.agentName.map {
                String(localized: "In review, but Paperclip didn’t wake up \($0) to review it, and the app’s automatic wake-up didn’t work either.")
            } ?? String(localized: "In review, but Paperclip didn’t wake up the reviewing agent to review it, and the app’s automatic wake-up didn’t work either.")
        )
    }

    /// Un traspaso que no se pudo comprobar: no se despierta a nadie y, pasado el margen, va la tarjeta que lo
    /// dice, una vez por traspaso. Un fallo de red o un 5xx espera a la revisión siguiente.
    private func unverifiedCard(
        _ partial: PartialHandoff,
        _ problem: ReadProblem,
        summary: ReviewIssue,
        company: PaperclipCompany,
        decisions: [AttentionItem],
        now: Date
    ) async -> AttentionItem? {
        let key = partial.key
        note(key, summary, "couldn't read \(problem.path): \(problem.detail)" + (problem.transient ? " (may be temporary)" : ""))
        // La tarjeta que ya se muestra para esta tarea sigue igual: lo que no se pudo leer ahora no arma otra.
        var shown = unverified.first { $0.value.issueId == summary.id && $0.value.showing }
        if shown == nil, unverified[key] == nil {
            if problem.transient {
                transientFailures[key, default: 0] += 1
                guard transientFailures[key, default: 0] >= Self.transientFailuresForCard else { return nil }
            }
            // Pasado el margen desde el traspaso, también si la tarea tenía la tarjeta de un traspaso anterior.
            guard !recent(summary, now: now) else { return nil }
            // El nombre, para el texto: con el lector de siempre, porque puede ser justo lo que no se pudo leer.
            var name: String?
            if let agentId = partial.agentId { name = await resolver.agentName(agentId) }
            let entry = Unverified(
                at: now, showing: true, companyId: company.id, issueId: summary.id, agentId: partial.agentId,
                agentName: name, identifier: summary.identifier, title: summary.title
            )
            unverified[key] = entry
            saveUnverified()
            shown = (key, entry)
            log.notice("\(summary.identifier ?? summary.id, privacy: .public): couldn't check the reviewer, card sent")
        }
        // Una sola vez por traspaso: la que ya se retiró no vuelve.
        guard let (shownKey, entry) = shown else { return nil }
        // Decisions ya muestra esa tarea trabada.
        if decisions.contains(where: { $0.wakeTarget?.issueId == summary.id }) { return nil }
        return Self.unverifiedItem(entry, key: shownKey, issuePrefix: company.issuePrefix)
    }

    /// La tarjeta de un traspaso que no se pudo comprobar: no afirma lo que no se leyó, y lleva el botón solo si
    /// se sabe quién es el revisor.
    static func unverifiedItem(_ entry: Unverified, key: String, issuePrefix: String?) -> AttentionItem? {
        card(
            id: "dispatch-review-unverified:\(key)",
            issueId: entry.issueId,
            identifier: entry.identifier,
            title: entry.title,
            agentId: entry.agentId,
            agentName: entry.agentName,
            issuePrefix: issuePrefix,
            whyNow: String(localized: "In review, but the app couldn’t check whether the reviewer is on its way."),
            text: entry.agentName.map {
                String(localized: "In review, but the app couldn’t check whether \($0) is on its way to review it: Paperclip’s answer couldn’t be read. Check the task in Paperclip.")
            } ?? String(localized: "In review, but the app couldn’t check whether the reviewing agent is on its way to review it: Paperclip’s answer couldn’t be read. Check the task in Paperclip.")
        )
    }

    /// Retira las tarjetas de «no se pudo comprobar» de una tarea (salvo la de `except`): ya se puede leer, o
    /// son de otro traspaso. No vuelven.
    private func retireUnverified(issueId: String, except key: String?) {
        var changed = false
        for (other, entry) in unverified where entry.issueId == issueId && entry.showing && other != key {
            unverified[other]?.showing = false
            changed = true
            log.notice("\(entry.identifier ?? issueId, privacy: .public): can read the review again, card dropped")
        }
        if changed { saveUnverified() }
    }

    /// La tarjeta de «Tarea trabada», con la forma de las de Decisions (`blocker_attention`) para que la Mac y
    /// Telegram la muestren igual. Con el botón «Despertar a …» (`nudge`) solo si se sabe a quién.
    private static func card(
        id: String,
        issueId: String,
        identifier: String?,
        title: String?,
        agentId: String?,
        agentName: String?,
        issuePrefix: String?,
        whyNow: String,
        text: String
    ) -> AttentionItem? {
        /// En JSON, un valor que falta va como `null`.
        func value(_ text: String?) -> Any { text.map { $0 as Any } ?? NSNull() }
        var href: Any = NSNull()
        if let issuePrefix, let identifier { href = "/\(issuePrefix)/issues/\(identifier)" }
        let json: [String: Any] = [
            "id": id,
            "sourceKind": "blocker_attention",
            "subject": [
                "kind": "issue",
                "id": issueId,
                "identifier": value(identifier),
                "title": value(title),
                "href": href,
                "metadata": ["assigneeAgentId": value(agentId)],
            ],
            "relatedIssue": [
                "kind": "issue",
                "id": issueId,
                "identifier": value(identifier),
                "href": href,
            ],
            "originAgentName": value(agentName),
            "whyNow": whyNow,
            "detail": ["promptExcerpt": text],
            "decisionVerbs": agentId == nil ? [] : [["id": "nudge"]],
            "inlineResolvable": false,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: json) else { return nil }
        return try? JSONDecoder().decode(AttentionItem.self, from: data)
    }

    /// Las corridas en cola o en curso de la tarea. Falla si alguna no se puede leer: así «sin corridas» no se
    /// confunde con «no se pudieron leer».
    private func liveRuns(on issueId: String) async throws(ReadProblem) -> [LiveRun] {
        try await read("api/issues/\(issueId)/live-runs")
    }

    /// Los despertares de un agente en una tarea, del más nuevo al más viejo. Falla si algún evento no se puede
    /// leer o si un despertar viene sin el id de su agente (así no se sabe de quién es), y si uno del agente trae
    /// un estado que la app no conoce.
    private func wakes(of agentId: String, on issueId: String) async throws(ReadProblem) -> [WakeEvent] {
        let path = "api/issues/\(issueId)/diagnostics/wakes"
        let diagnostics: WakeDiagnostics = try await read(path)
        let mine = diagnostics.events.filter { $0.kind == "wake_request" && $0.agentId == agentId }
        if let problem = mine.lazy.compactMap(\.problem).first {
            throw ReadProblem(path: path, detail: problem, transient: false)
        }
        return mine
    }

    /// Lee una respuesta de Paperclip y, si no se puede, dice qué ruta y qué no se pudo leer.
    private func read<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws(ReadProblem) -> T {
        do {
            return try await api.get(path, query: query)
        } catch let error as DecodingError {
            throw ReadProblem(path: path, detail: Self.describe(error), transient: false)
        } catch let PaperclipAPI.APIError.http(status, message) {
            throw ReadProblem(
                path: path,
                detail: "HTTP \(status)" + (message.map { " (\($0))" } ?? ""),
                transient: status >= 500
            )
        } catch PaperclipAPI.APIError.signedOut {
            // Sin sesión falla toda la revisión; no es una respuesta cambiada.
            throw ReadProblem(path: path, detail: "signed out", transient: true)
        } catch {
            throw ReadProblem(path: path, detail: error.localizedDescription, transient: true)
        }
    }

    /// Qué no se pudo leer de un JSON, para el registro.
    private static func describe(_ error: DecodingError) -> String {
        func at(_ context: DecodingError.Context) -> String {
            let path = context.codingPath.map { $0.intValue.map { "[\($0)]" } ?? $0.stringValue }.joined(separator: ".")
            return path.isEmpty ? "" : " at \(path)"
        }
        return switch error {
        case let .keyNotFound(key, context): "missing \(key.stringValue)" + at(context)
        case let .valueNotFound(_, context): "null value" + at(context)
        case let .typeMismatch(_, context): "unexpected type" + at(context)
        case let .dataCorrupted(context): context.debugDescription + at(context)
        @unknown default: "unreadable JSON"
        }
    }

    private func record(_ attempt: Attempt, for key: String) {
        attempts[key] = attempt
        save()
    }

    private func prune(now: Date) {
        let kept = attempts.filter { now.timeIntervalSince($0.value.at) < Self.keepAttempts }
        if kept.count != attempts.count {
            attempts = kept
            save()
        }
        let keptUnverified = unverified.filter { now.timeIntervalSince($0.value.at) < Self.keepAttempts }
        if keptUnverified.count != unverified.count {
            unverified = keptUnverified
            saveUnverified()
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(attempts) else { return }
        UserDefaults.standard.set(data, forKey: Self.attemptsKey)
    }

    private func saveUnverified() {
        guard let data = try? JSONEncoder().encode(unverified) else { return }
        UserDefaults.standard.set(data, forKey: Self.unverifiedKey)
    }

    /// Lo que se decidió de un traspaso, en el registro de macOS (`log show`), solo cuando cambia.
    private func note(_ key: String, _ issue: ReviewIssue, _ decision: String) {
        note(key, issue.identifier ?? issue.id, decision)
    }

    private func note(_ key: String, _ label: String, _ decision: String) {
        guard lastDecision[key] != decision else { return }
        lastDecision[key] = decision
        log.notice("\(label, privacy: .public): \(decision, privacy: .public)")
    }

    /// Lo que falló al leer la lista de una company, solo cuando cambia. `nil`: se leyó bien.
    private func noteList(_ company: PaperclipCompany, _ problem: String?) {
        guard listProblem[company.id] != problem else { return }
        listProblem[company.id] = problem
        if let problem { log.notice("\(company.issuePrefix ?? company.id, privacy: .public): \(problem, privacy: .public)") }
    }

    nonisolated private static func date(_ text: String) -> Date? {
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

        /// Lo que no se pudo leer va como `?`.
        static func key(_ issueId: String, _ stageId: String?, _ round: Int?, _ agentId: String?) -> String {
            [issueId, stageId ?? "?", round.map(String.init) ?? "?", agentId ?? "?"].joined(separator: ":")
        }
    }

    /// Un traspaso que no se pudo leer entero. `agentId`, solo si se leyó bien al participante.
    struct PartialHandoff {
        let key: String
        let agentId: String?
    }

    /// La etapa de una tarea en revisión.
    enum StageReading {
        /// No es una etapa pendiente a cargo del agente que la tiene (sin etapas, la revisa una persona…).
        case none(String)
        case agent(Handoff)
        case unreadable(PartialHandoff, ReadProblem)
    }

    /// Una tarea de la lista de las que están en revisión, leída campo por campo: solo el `id` es obligatorio,
    /// y lo demás se vuelve a leer de la tarea.
    struct ReviewIssue: Decodable {
        let id: String
        let identifier: String?
        let title: String?
        let status: String?
        let assigneeAgentId: String?
        /// Si la lista dice quién la tiene (aunque sea `null`, una persona o nadie).
        let assigneeKnown: Bool
        let updatedAt: String?

        private enum CodingKeys: String, CodingKey { case id, identifier, title, status, assigneeAgentId, updatedAt }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            identifier = try? container.decodeIfPresent(String.self, forKey: .identifier)
            title = try? container.decodeIfPresent(String.self, forKey: .title)
            status = try? container.decodeIfPresent(String.self, forKey: .status)
            let assignee = Result { try container.decodeIfPresent(String.self, forKey: .assigneeAgentId) }
            assigneeAgentId = try? assignee.get()
            assigneeKnown = container.contains(.assigneeAgentId) && (try? assignee.get()) != nil
            updatedAt = try? container.decodeIfPresent(String.self, forKey: .updatedAt)
        }
    }

    /// Una tarea leída sola, con su etapa (`executionPolicy` y `executionState`). Se lee campo por campo para
    /// saber qué no se pudo leer y armar la clave del traspaso con lo que sí.
    struct IssueDetail: Decodable {
        let id: String
        let status: String
        let assigneeAgentId: String?
        private let policyStages: Int?
        private let state: State?
        /// Lo que no se pudo leer de la etapa.
        private let problem: String?

        private enum CodingKeys: String, CodingKey { case id, status, assigneeAgentId, executionPolicy, executionState }
        private enum PolicyKeys: String, CodingKey { case stages }

        struct State {
            let status: String?
            let stageId: String?
            let round: Int?
            let participantType: String?
            let agentId: String?
            let problem: String?
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            status = try container.decode(String.self, forKey: .status)
            assigneeAgentId = try container.decodeIfPresent(String.self, forKey: .assigneeAgentId)
            // Las dos claves vienen siempre, aunque sea en `null`: si falta una, la respuesta cambió.
            guard container.contains(.executionPolicy), container.contains(.executionState) else {
                policyStages = nil
                state = nil
                problem = "missing executionPolicy or executionState"
                return
            }
            if try container.decodeNil(forKey: .executionPolicy) {
                policyStages = 0
                state = nil
                problem = nil
                return
            }
            guard let policy = try? container.nestedContainer(keyedBy: PolicyKeys.self, forKey: .executionPolicy),
                  let stages = try? policy.decode([PresentValue].self, forKey: .stages)
            else {
                policyStages = nil
                state = nil
                problem = "unexpected executionPolicy.stages"
                return
            }
            policyStages = stages.count
            if try container.decodeNil(forKey: .executionState) {
                state = nil
                problem = nil
                return
            }
            state = try? container.decode(StateReader.self, forKey: .executionState).state
            problem = state == nil ? "executionState is not an object" : nil
        }

        /// La etapa pendiente a cargo de un agente, si la tarea sigue a su nombre; o lo que no se pudo leer.
        func reading(path: String) -> StageReading {
            func unreadable(_ detail: String) -> StageReading {
                .unreadable(
                    PartialHandoff(key: Handoff.key(id, state?.stageId, state?.round, state?.agentId), agentId: state?.agentId),
                    ReadProblem(path: path, detail: detail, transient: false)
                )
            }
            if let problem { return unreadable(problem) }
            guard status == "in_review" else { return .none("no longer in review") }
            guard let policyStages, policyStages > 0 else { return .none("no review stages") }
            guard let state else { return .none("no review stage in progress") }
            guard let stageStatus = state.status else { return unreadable("missing executionState.status") }
            guard ReviewWaker.stageStatuses.contains(stageStatus) else {
                return unreadable("unknown executionState.status “\(stageStatus)”")
            }
            guard stageStatus == "pending" else { return .none("review stage is \(stageStatus)") }
            if state.participantType == "user" { return .none("a person reviews it") }
            if let problem = state.problem { return unreadable(problem) }
            guard let stageId = state.stageId else { return unreadable("missing executionState.currentStageId") }
            guard let round = state.round else { return unreadable("unexpected executionState.changesRequestedCount") }
            guard let agentId = state.agentId else { return unreadable("missing currentParticipant.agentId") }
            guard assigneeAgentId == agentId else { return .none("not assigned to the stage’s agent") }
            return .agent(Handoff(key: Handoff.key(id, stageId, round, agentId), agentId: agentId))
        }

        /// `executionState`, sin fallar: lo que no se puede leer queda en `problem`.
        private struct StateReader: Decodable {
            let state: State

            private enum Keys: String, CodingKey { case status, currentStageId, currentParticipant, changesRequestedCount }
            private enum ParticipantKeys: String, CodingKey { case type, agentId }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: Keys.self)
                let status = try? container.decode(String.self, forKey: .status)
                let stageId = try? container.decode(String.self, forKey: .currentStageId)
                // Las versiones viejas no la traen: sin ella, es la primera vuelta.
                let round: Int? = container.contains(.changesRequestedCount)
                    ? try? container.decode(Int.self, forKey: .changesRequestedCount) : 0
                var type: String?
                var agentId: String?
                var problem: String?
                if let participant = try? container.nestedContainer(keyedBy: ParticipantKeys.self, forKey: .currentParticipant) {
                    type = try? participant.decode(String.self, forKey: .type)
                    if let type, !ReviewWaker.participantTypes.contains(type) {
                        problem = "unknown currentParticipant.type “\(type)”"
                    } else if type == nil {
                        problem = "missing currentParticipant.type"
                    } else if type == "agent" {
                        agentId = try? participant.decode(String.self, forKey: .agentId)
                    }
                } else {
                    problem = "missing currentParticipant"
                }
                state = State(status: status, stageId: stageId, round: round, participantType: type, agentId: agentId, problem: problem)
            }
        }
    }

    private struct ReviewAgent: Decodable {
        let name: String?
        let status: String
        let pauseReason: String?
        let budgetMonthlyCents: Int?
        let spentMonthlyCents: Int?

        private enum CodingKeys: String, CodingKey { case name, status, pauseReason, budgetMonthlyCents, spentMonthlyCents }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try? container.decodeIfPresent(String.self, forKey: .name)
            status = try container.decodeKnown(.status, in: ReviewWaker.agentStatuses)
            pauseReason = try? container.decodeIfPresent(String.self, forKey: .pauseReason)
            budgetMonthlyCents = try container.decodeIfPresent(Int.self, forKey: .budgetMonthlyCents)
            spentMonthlyCents = try container.decodeIfPresent(Int.self, forKey: .spentMonthlyCents)
        }
    }

    /// Una corrida de `live-runs`: con su agente y un estado que la app conoce, o la lista entera no se lee.
    private struct LiveRun: Decodable {
        let agentId: String
        let status: String

        private enum CodingKeys: String, CodingKey { case agentId, status }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            agentId = try container.decode(String.self, forKey: .agentId)
            status = try container.decodeKnown(.status, in: ReviewWaker.liveRunStatuses)
        }
    }

    private struct WakeDiagnostics: Decodable {
        let events: [WakeEvent]
    }

    /// Un evento de `diagnostics/wakes`. Un despertar trae su agente, su estado y cuándo se pidió; si no, la
    /// lista entera no se lee. Un estado desconocido o una fecha ilegible quedan en `problem`: solo importan si
    /// el despertar es del revisor.
    private struct WakeEvent: Decodable {
        let kind: String
        let agentId: String?
        let status: String?
        let requestedAt: String?
        let problem: String?

        private enum CodingKeys: String, CodingKey { case kind, agentId, status, requestedAt }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            kind = try container.decodeKnown(.kind, in: ReviewWaker.wakeEventKinds)
            guard kind == "wake_request" else {
                agentId = nil
                status = nil
                requestedAt = nil
                problem = nil
                return
            }
            let agentId = try container.decode(String.self, forKey: .agentId)
            let status = try container.decode(String.self, forKey: .status)
            let requested = try container.decode(String.self, forKey: .requestedAt)
            self.agentId = agentId
            self.status = status
            requestedAt = requested
            problem = if !ReviewWaker.wakeStatuses.contains(status) {
                "unknown status “\(status)” in a wake of \(agentId)"
            } else if ReviewWaker.date(requested) == nil {
                "unreadable requestedAt “\(requested)” in a wake of \(agentId)"
            } else {
                nil
            }
        }
    }
}

private extension KeyedDecodingContainer {
    /// Un texto que tiene que ser uno de los que conoce la app.
    func decodeKnown(_ key: Key, in known: Set<String>) throws -> String {
        let value = try decode(String.self, forKey: key)
        guard known.contains(value) else {
            throw DecodingError.dataCorruptedError(forKey: key, in: self, debugDescription: "unknown \(key.stringValue) “\(value)”")
        }
        return value
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
