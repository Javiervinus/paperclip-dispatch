import Foundation
import os
import SwiftUI

// Despertar automático del agente al que Paperclip le pasa una tarea y se olvida de despertar.
//
// Es un bug de Paperclip 2026.1023.0 (https://github.com/paperclipai/paperclip/issues/18315): cuando un agente
// pasa una tarea a otro desde su propia corrida, Paperclip descarta el despertar del que la recibe (`skipped`,
// «The previous execution has not released its environment lease»). Pasa en los dos sentidos: en la ida al
// revisor nada lo reintenta, y en la vuelta al ejecutor (cuando el revisor pide cambios) Paperclip suele
// rescatarlo solo (`issue_continuation_needed`), pero no siempre. La tarea queda con alguien a cargo que no
// está trabajando en ella.
//
// Todo vive en este archivo para quitarlo de una vez cuando Paperclip publique el arreglo (VIN-242). Lo demás
// son enganches: el ajuste (`Preferences.wakeMissedHandoffs`), la llamada en cada revisión de Decisions
// (`DecisionsMonitor`), la sección de Ajustes (`HandoffWakeSection` en la pestaña Paperclip), las escenas de
// `NotificationsSnapshot` y los parámetros de `DecisionResolver.wake`.
//
// Solo cuenta un traspaso que la app vio pasar entre dos revisiones seguidas: así, al abrirse, no despierta a
// nadie en tareas viejas paradas (esas siguen llegando por Decisions). Lo que se lee de Paperclip se lee
// estricto, con lectores propios (no con los de la parte C, que descartan lo que no entienden): si una
// respuesta no se puede leer bien, no se sabe si el agente va en camino, y no se despierta a nadie. Pasado el
// margen llega la tarjeta de la tarea trabada, que dice que no se pudo comprobar.

/// Mira en cada vuelta las tareas abiertas de una company y, cuando ve que una pasó a un agente, lo despierta
/// una sola vez si pasado el margen sigue sin ponerse en camino. Si lo despierta, no avisa nada. Si Paperclip
/// lo salta o falla, o si lo que contesta Paperclip no se puede leer, devuelve la tarjeta de «Tarea trabada»,
/// que el monitor suma a lo de Decisions para que llegue a la Mac y a Telegram como cualquier otra.
@MainActor
final class HandoffWaker {
    /// Lo que se espera desde que la app ve el traspaso antes de despertar: un despertar de Paperclip que sí
    /// llega (o su rescate) tarda segundos, y así no se le adelanta.
    static let margin: TimeInterval = 2 * 60
    /// Un hueco más largo que esto desde que terminó la vuelta anterior que leyó la lista (la Mac durmió, la app
    /// estuvo sin sesión): la app no vio lo que pasó en medio, y esa lectura solo toma nota.
    static let maxGap: TimeInterval = 5 * 60
    /// El `reason` de estos despertares, para distinguirlos de los del botón en el historial de Paperclip.
    static let wakeReason = "dispatch_handoff_wake_recovery"
    /// Lo intentado, por traspaso. Sobrevive a un reinicio para no gastar corridas en bucle.
    private static let attemptsKey = "handoffWakeAttempts"
    /// Las tarjetas de «no se pudo comprobar», por traspaso: una sola vez cada una, también tras un reinicio.
    private static let unverifiedKey = "handoffWakeUnverified"
    /// Lo que guardaba la primera versión de esta función, que no llegó a publicarse (también su ajuste).
    private static let retiredKeys = ["reviewWakeAttempts", "reviewWakeUnverified", "wakeStrandedReviewers"]
    /// Entre dos vueltas en que un traspaso tuvo que esperar, se espera cada vez el doble, hasta esto: un agente
    /// pausado o sin presupuesto puede tardar horas, y cada vuelta son cuatro lecturas.
    private static let maxWaitInterval: TimeInterval = 10 * 60
    /// Cuánto se recuerda un intento.
    private static let keepAttempts: TimeInterval = 30 * 24 * 60 * 60
    /// Las veces seguidas que tiene que fallar una lectura por red o por un 5xx antes de mandar la tarjeta.
    private static let transientFailuresForCard = 2
    /// Los estados de trabajo: lo que se lee de cada company en cada vuelta.
    private static let workStatuses = ["todo", "in_progress", "in_review"]
    /// Tareas por página de la lista (el máximo que acepta Paperclip es 1000).
    private static let pageLimit = 500
    /// Más páginas que esto no es una company real: la lista no se da por leída.
    private static let maxPages = 20

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
    /// Despertares que Paperclip descarta a propósito (`reason`): la tarea espera a otras, su árbol está en pausa
    /// o el agente no acepta despertares. Despertarlo también se descartaría. El del bug llega como `other`.
    nonisolated private static let heldWakeReasons: Set<String> = [
        "issue_dependencies_blocked", "issue_tree_hold_active", "heartbeat.disabled", "heartbeat.wakeOnDemand.disabled",
    ]
    /// `live-runs` y `activeRun`: solo traen corridas en cola o en curso.
    nonisolated private static let liveRunStatuses: Set<String> = ["queued", "running"]
    /// `status` de una tarea.
    nonisolated private static let issueStatuses: Set<String> = [
        "backlog", "todo", "in_progress", "in_review", "blocked", "done", "cancelled",
    ]
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
            /// Se guarda antes de pedirlo: si la app se cierra a mitad, no se vuelve a intentar y, si el agente
            /// no se puso en camino, sale la tarjeta como si hubiera fallado.
            case requested
            /// Paperclip lo aceptó, o ya no hacía falta.
            case done
            /// Paperclip lo saltó o falló: va la tarjeta con el botón.
            case failed
            /// La tarjeta ya no hace falta: el agente se puso en camino (p. ej. con el botón) o la tarea pasó a
            /// otra cosa.
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
        /// El agente a cargo según la lista: mientras la tarea siga a su nombre, se vuelve a mirar.
        var assigneeAgentId: String
        /// Cuándo vio la app el traspaso, y la lectura anterior (con la hora de Paperclip): sobreviven a un
        /// reinicio con la tarjeta.
        var seenAt: Date
        var since: Date
        /// Solo si se leyó bien quién está a cargo: sin él, la tarjeta no lleva el botón.
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

    /// Un traspaso que la app vio pasar y que todavía no se resolvió.
    private struct Pending {
        let key: String
        let companyId: String
        let issueId: String
        let agentId: String
        /// La revisión en que la app lo vio: desde aquí corre el margen.
        let seenAt: Date
        /// La revisión anterior, con la hora de Paperclip: el traspaso pasó después. Una corrida del agente
        /// pedida desde entonces cuenta como que ya pasó por la tarea.
        let since: Date
        /// Las vueltas seguidas en que tuvo que esperar, y cuándo se vuelve a mirar.
        var waits = 0
        var nextCheck: Date?
    }

    /// Lo que se decidió de un traspaso en una vuelta.
    private enum Decision {
        /// Resuelto: se despertó al agente (queda el intento guardado) o no hacía falta.
        case settled
        /// Se vuelve a mirar en la vuelta siguiente (va en camino, está pausado…).
        case wait(String)
        /// Visto antes de que la app dejara de mirar (se cerró o hubo un hueco): no se despierta a nadie, y su
        /// tarjeta de «no se pudo comprobar» sigue hasta que el agente se ponga en camino o la tarea cambie.
        case held(String)
        /// Ya no es un traspaso a un agente que haya que mirar (otra persona a cargo, salió de los estados de
        /// trabajo…).
        case drop(String)
        /// No se pudo leer. `agentKnown`: si se leyó bien quién está a cargo.
        case unreadable(ReadProblem, agentKnown: Bool)
    }

    /// Lo que la app vio de una company en una lectura de la lista.
    private struct Snapshot {
        /// La hora de la lectura, en el reloj de Paperclip (o en el de la Mac si no vino).
        let serverAt: Date
        let issues: [String: ListedIssue]
    }

    private let api: PaperclipAPI
    private let resolver: DecisionResolver
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "PaperclipDispatch", category: "handoff-wake")
    private var attempts: [String: Attempt]
    private var unverified: [String: Unverified]
    /// La última lista que se leyó bien, por company.
    private var snapshots: [String: Snapshot] = [:]
    /// Los traspasos vistos que siguen sin resolver, por tarea.
    private var pending: [String: Pending] = [:]
    /// Las tarjetas de la última vuelta, por company: si la lista no se puede leer, siguen las mismas.
    private var lastCards: [String: [AttentionItem]] = [:]
    /// Las lecturas seguidas que fallaron por red o por un 5xx, por traspaso.
    private var transientFailures: [String: Int] = [:]
    /// Lo último que se decidió de cada traspaso, para anotarlo en el registro solo cuando cambia.
    private var lastDecision: [String: String] = [:]
    /// Lo último que falló al leer la lista de cada company, por lo mismo.
    private var listProblem: [String: String] = [:]
    /// Cuánto va adelantado el reloj de Paperclip respecto del de la Mac, por company: las horas de sus
    /// despertares se comparan con las de la app en un mismo reloj.
    private var clockOffset: [String: TimeInterval] = [:]
    /// Desde cuándo la app sigue cada company sin cortes: solo se despierta en los traspasos vistos desde entonces.
    private var watchingSince: [String: Date] = [:]
    /// Cuándo terminó la última vuelta que leyó la lista, por company: el hueco se mide desde ahí, así una
    /// vuelta lenta no cuenta como hueco.
    private var lastChecked: [String: Date] = [:]

    init(api: PaperclipAPI, resolver: DecisionResolver) {
        self.api = api
        self.resolver = resolver
        attempts = UserDefaults.standard.data(forKey: Self.attemptsKey)
            .flatMap { try? JSONDecoder().decode([String: Attempt].self, from: $0) } ?? [:]
        unverified = UserDefaults.standard.data(forKey: Self.unverifiedKey)
            .flatMap { try? JSONDecoder().decode([String: Unverified].self, from: $0) } ?? [:]
        Self.retiredKeys.forEach(UserDefaults.standard.removeObject(forKey:))
    }

    /// Una company en una vuelta del monitor. `decisions`: lo que ya trae Decisions, para no duplicar la tarjeta
    /// de una tarea que ya está ahí. Devuelve las tarjetas de los despertares que fallaron y de los traspasos
    /// que no se pudieron comprobar.
    func check(_ company: PaperclipCompany, decisions: [AttentionItem]) async -> [AttentionItem] {
        let now = Date()
        // Una lectura por company (con sus páginas): las tareas en los estados de trabajo. Lo demás se lee solo
        // de los traspasos vistos, pasado el margen.
        let listed: [ListedIssue]
        do {
            let serverDate: Date?
            (listed, serverDate) = try await openIssues(of: company)
            if let serverDate {
                let offset = serverDate.timeIntervalSince(now)
                if abs(offset - (clockOffset[company.id] ?? 0)) > 5 {
                    log.notice("\(company.issuePrefix ?? company.id, privacy: .public): Paperclip's clock is \(Int(offset)) s off the Mac's")
                }
                clockOffset[company.id] = offset
            }
        } catch {
            // Sin la lista no se sabe qué cambió: siguen las tarjetas de la vuelta anterior, sin volver a mirar,
            // y la lectura siguiente se compara con la última que salió bien.
            noteList(company, "couldn't read \(error.path): \(error.detail)")
            return lastCards[company.id] ?? []
        }
        let previous = snapshots[company.id]
        let current = record(listed, of: company, previous: previous, now: now)
        defer { lastChecked[company.id] = Date() }
        if let previous, let last = lastChecked[company.id], now.timeIntervalSince(last) <= Self.maxGap {
            detectHandoffs(listed, in: company, previous: previous, now: now)
        } else {
            // Al abrir la app, o después de un hueco: solo se toma nota de cómo están las cosas. Lo que se vio
            // antes ya no despierta a nadie; solo se sigue mirando lo que tiene una tarjeta a la vista.
            log.notice("\(company.issuePrefix ?? company.id, privacy: .public): taking note of \(current.count) open tasks")
            watchingSince[company.id] = now
            pending = pending.filter { _, handoff in
                handoff.companyId != company.id || unverified[handoff.key]?.showing == true
            }
        }

        var cards: [AttentionItem] = []
        // Lo que ya no está a nombre del mismo agente deja de mirarse, y sus tarjetas se retiran.
        pending = pending.filter { _, handoff in
            handoff.companyId != company.id || current[handoff.issueId]?.isAssigned(to: handoff.agentId) == true
        }
        retireMovedOn(company, current: current)
        // Las tarjetas de «no se pudo comprobar» que siguen a la vista se vuelven a mirar, también tras un reinicio.
        for (key, entry) in unverified where entry.companyId == company.id && entry.showing && pending[entry.issueId] == nil {
            pending[entry.issueId] = Pending(
                key: key, companyId: company.id, issueId: entry.issueId, agentId: entry.assigneeAgentId,
                seenAt: entry.seenAt, since: entry.since
            )
        }
        // Los despertares que fallaron: su tarjeta, mientras el agente no se ponga en camino.
        for (key, attempt) in attempts.sorted(by: { $0.value.at < $1.value.at })
        where attempt.companyId == company.id && attempt.showsCard {
            if let card = await failedCard(attempt, key: key, company: company, decisions: decisions) { cards.append(card) }
        }
        for handoff in pending.values.filter({ $0.companyId == company.id }).sorted(by: { $0.seenAt < $1.seenAt }) {
            guard let issue = current[handoff.issueId] else { continue }
            if attempts[handoff.key] != nil {
                pending[handoff.issueId] = nil
                continue
            }
            let hasCard = unverified[handoff.key]?.showing == true
            if !hasCard, now.timeIntervalSince(handoff.seenAt) < Self.margin {
                note(handoff.key, issue, "waiting for the margin")
                continue
            }
            if let next = handoff.nextCheck, now < next {
                // No toca mirarlo en esta vuelta: su tarjeta, si la tiene, sigue igual.
                if let card = showingUnverifiedCard(handoff, company: company, decisions: decisions) { cards.append(card) }
                continue
            }
            let decision: Decision
            if let run = issue.activeRun, run.agentId == handoff.agentId {
                // La lista ya dice que el agente corre en la tarea: no hace falta leer más.
                decision = .wait("agent has an active run on the task")
            } else {
                decision = await consider(handoff, issue: issue, company: company, now: now)
            }
            switch decision {
            case let .unreadable(problem, agentKnown):
                if let card = await unverifiedCard(
                    handoff, problem, agentKnown: agentKnown, issue: issue, company: company, decisions: decisions, now: now
                ) {
                    cards.append(card)
                }
                continue
            case .settled:
                pending[handoff.issueId] = nil
            case let .held(reason):
                note(handoff.key, issue, reason)
                transientFailures[handoff.key] = nil
                backOff(handoff, now: now)
                // Su tarjeta sigue a la vista: el agente no va en camino y la app no lo despierta.
                if let card = showingUnverifiedCard(handoff, company: company, decisions: decisions) { cards.append(card) }
                continue
            case let .wait(reason):
                note(handoff.key, issue, reason)
                // Una corrida en curso según la lista no cuesta lecturas: se mira en cada vuelta.
                if issue.activeRun?.agentId != handoff.agentId { backOff(handoff, now: now) }
            case let .drop(reason):
                note(handoff.key, issue, reason)
                pending[handoff.issueId] = nil
            }
            // Se pudo leer: la tarjeta de «no se pudo comprobar», si la había, ya no hace falta.
            transientFailures[handoff.key] = nil
            retireUnverified(key: handoff.key)
            if let attempt = attempts[handoff.key], attempt.showsCard,
               let card = await failedCard(attempt, key: handoff.key, company: company, decisions: decisions) {
                cards.append(card)
            }
        }
        prune(now: now)
        lastCards[company.id] = cards
        return cards
    }

    /// Un traspaso que tuvo que esperar se vuelve a mirar cada vez más espaciado, hasta `maxWaitInterval`.
    private func backOff(_ handoff: Pending, now: Date) {
        var waiting = handoff
        waiting.waits += 1
        waiting.nextCheck = now.addingTimeInterval(min(Self.maxWaitInterval, 60 * pow(2, Double(waiting.waits - 1))))
        pending[handoff.issueId] = waiting
    }

    /// Guarda la lista de esta vuelta y la devuelve por tarea. Una tarea que no se pudo leer bien conserva lo
    /// que se vio de ella antes: así, cuando se vuelva a leer, no parece que cambió.
    private func record(
        _ listed: [ListedIssue],
        of company: PaperclipCompany,
        previous: Snapshot?,
        now: Date
    ) -> [String: ListedIssue] {
        var issues: [String: ListedIssue] = [:]
        for issue in listed {
            if issue.readable {
                // Una tarea que salió de los estados de trabajo (la lista la trae igual si cambió el filtro).
                guard Self.workStatuses.contains(issue.status ?? "") else { continue }
                issues[issue.id] = issue
            } else {
                issues[issue.id] = previous?.issues[issue.id] ?? issue
            }
        }
        snapshots[company.id] = Snapshot(
            serverAt: now.addingTimeInterval(clockOffset[company.id] ?? 0), issues: issues
        )
        return issues
    }

    /// Los traspasos entre la lectura anterior y esta: la tarea cambió de agente a cargo (de otro agente, de una
    /// persona o de nadie), o apareció en la lista ya a nombre de un agente (nueva, reabierta o salida de
    /// `backlog` o de `blocked`). Que el agente tome su tarea o la deje en revisión no cambia el asignado.
    private func detectHandoffs(_ listed: [ListedIssue], in company: PaperclipCompany, previous: Snapshot, now: Date) {
        for issue in listed where issue.readable && Self.workStatuses.contains(issue.status ?? "") {
            guard let agentId = issue.assigneeAgentId else { continue }
            if let before = previous.issues[issue.id] {
                // Antes no se pudo leer quién la tenía: no se sabe si cambió.
                guard before.readable, before.assigneeAgentId != agentId else { continue }
            }
            // `statusVersion` sube con cada cambio de estado o de asignado: dos traspasos de la misma tarea no
            // comparten clave. Si no viene, la hora en que se vio.
            let version = issue.statusVersion.map(String.init) ?? "t\(Int(now.timeIntervalSince1970))"
            let key = [issue.id, version, agentId].joined(separator: ":")
            pending[issue.id] = Pending(
                key: key, companyId: company.id, issueId: issue.id, agentId: agentId, seenAt: now,
                since: previous.serverAt
            )
            // Las tarjetas de un traspaso anterior de esta tarea ya no valen.
            retireCards(issueId: issue.id, except: key)
            note(key, issue, "handed over to agent \(agentId)")
        }
    }

    /// Retira las tarjetas de las tareas que salieron de la lista o pasaron a otro: ya no están trabadas con
    /// ese agente.
    private func retireMovedOn(_ company: PaperclipCompany, current: [String: ListedIssue]) {
        var changed = false
        for (key, attempt) in attempts where attempt.companyId == company.id && attempt.showsCard {
            guard current[attempt.issueId]?.isAssigned(to: attempt.agentId) == false || current[attempt.issueId] == nil
            else { continue }
            attempts[key]?.outcome = .recovered
            changed = true
            log.notice("\(attempt.identifier ?? attempt.issueId, privacy: .public): the task moved on, card dropped")
        }
        if changed { save() }
        for (key, entry) in unverified where entry.companyId == company.id && entry.showing {
            guard current[entry.issueId]?.isAssigned(to: entry.assigneeAgentId) == false || current[entry.issueId] == nil
            else { continue }
            retireUnverified(key: key, reason: "the task moved on")
        }
    }

    /// Un traspaso pasado el margen y sin intento: lo despierta si el agente de verdad se quedó dormido. Si algo
    /// no se pudo leer, no despierta a nadie.
    private func consider(_ handoff: Pending, issue: ListedIssue, company: PaperclipCompany, now: Date) async -> Decision {
        // Visto antes de que la app se cerrara o de un hueco: no se despierta a nadie. Solo se mira si el agente ya
        // va en camino o corrió, para retirar su tarjeta (que la tarea cambió lo dice la lista).
        if handoff.seenAt < watchingSince[company.id, default: .distantFuture] {
            return await heldDecision(handoff)
        }
        let path = "api/issues/\(handoff.issueId)"
        let detail: IssueDetail
        do {
            detail = try await read(path)
        } catch {
            // La lista sí dijo quién la tiene: el botón puede ir.
            return .unreadable(error, agentKnown: true)
        }
        if let problem = detail.problem(for: handoff.agentId, path: path) {
            return .unreadable(problem.problem, agentKnown: problem.agentKnown)
        }
        // Paperclip salta los despertares de una tarea `blocked` o cerrada.
        guard Self.workStatuses.contains(detail.status) else { return .drop("task is \(detail.status)") }
        guard detail.assigneeAgentId == handoff.agentId else { return .drop("handed over to someone else") }
        if let reason = detail.notTheStageAgent(handoff.agentId) { return .drop(reason) }

        let agent: HandoffAgent
        do {
            agent = try await read("api/agents/\(handoff.agentId)")
        } catch {
            return .unreadable(error, agentKnown: true)
        }
        if Self.unavailableAgentStatuses.contains(agent.status) {
            return .wait("agent is \(agent.status)" + (agent.pauseReason.map { " (\($0))" } ?? ""))
        }
        if let budget = agent.budgetMonthlyCents, budget > 0, (agent.spentMonthlyCents ?? 0) >= budget {
            return .wait("agent is out of budget")
        }
        let runs: [LiveRun]
        do {
            runs = try await liveRuns(on: handoff.issueId)
        } catch {
            return .unreadable(error, agentKnown: true)
        }
        if runs.contains(where: { $0.agentId == handoff.agentId }) {
            return .wait("agent has a queued or running run")
        }
        let mine: [WakeEvent]
        do {
            mine = try await wakes(of: handoff.agentId, on: handoff.issueId)
        } catch {
            return .unreadable(error, agentKnown: true)
        }
        // Solo cuenta lo del agente a cargo: un despertar pendiente de otro (p. ej. el del ingeniero, que quedó
        // huérfano al pasar la tarea a revisión) no lo lleva a la tarea.
        if mine.contains(where: { Self.onItsWay($0, liveRuns: runs) }) {
            return .wait("agent has a pending wake-up")
        }
        // El último despertar suyo lo descartó Paperclip a propósito: el agente se despierta cuando eso cambie.
        let requested = { (event: WakeEvent) in event.requestedAt.flatMap(Self.date) ?? .distantPast }
        if let latest = mine.max(by: { requested($0) < requested($1) }),
           let reason = latest.reason, Self.heldWakeReasons.contains(reason) {
            return .drop("Paperclip held the agent's wake-up on purpose (\(reason))")
        }
        if mine.contains(where: { $0.status == "deferred_issue_execution" }) {
            // Espera a una corrida que ya no está: Paperclip no lo va a soltar solo (pasó en una reasignación
            // hecha desde la corrida del agente anterior). Un despertar nuevo lo destraba.
            note(handoff.key, issue, "agent's deferred wake-up has no run to wait for")
        }
        // Una corrida suya pedida después de la lectura anterior al traspaso (p. ej. el rescate de Paperclip,
        // `issue_continuation_needed`, aunque ya haya terminado): ya pasó por la tarea y no se quedó dormido.
        if mine.contains(where: { event in
            Self.ranWakeStatuses.contains(event.status ?? "")
                && (event.requestedAt.flatMap(Self.date).map { $0 > handoff.since } ?? false)
        }) {
            // No se guarda: un traspaso ya resuelto no vuelve a verse (la clave cambia con cada traspaso).
            note(handoff.key, issue, "agent already ran after the handoff")
            return .settled
        }

        var attempt = Attempt(
            at: now, outcome: .requested, companyId: company.id, issueId: handoff.issueId, agentId: handoff.agentId,
            agentName: agent.name.flatMap { $0.isEmpty ? nil : $0 }, identifier: issue.identifier, title: issue.title
        )
        record(attempt, for: handoff.key)
        let outcome = await resolver.wake(
            WakeTarget(agentId: handoff.agentId, issueId: handoff.issueId, issueIdentifier: issue.identifier),
            reason: Self.wakeReason,
            triggerDetail: "system",
            idempotencyKey: "paperclip-dispatch:handoff-wake:\(handoff.key)"
        )
        attempt.outcome = switch outcome {
        case .accepted, .alreadyRunning, .notStuck: .done
        case .skipped, .failed: .failed
        }
        record(attempt, for: handoff.key)
        note(handoff.key, issue, "woke the agent: \(outcome)")
        return .settled
    }

    /// Un traspaso que la app no siguió sin cortes: va en camino o ya corrió (la tarjeta se retira), o sigue
    /// retenido (la tarjeta sigue, aunque el agente esté pausado: no va en camino).
    private func heldDecision(_ handoff: Pending) async -> Decision {
        let runs: [LiveRun]
        let mine: [WakeEvent]
        do {
            runs = try await liveRuns(on: handoff.issueId)
            mine = try await wakes(of: handoff.agentId, on: handoff.issueId)
        } catch {
            return .unreadable(error, agentKnown: true)
        }
        if runs.contains(where: { $0.agentId == handoff.agentId }) { return .wait("agent has a queued or running run") }
        if mine.contains(where: { Self.onItsWay($0, liveRuns: runs) }) { return .wait("agent has a pending wake-up") }
        if mine.contains(where: { event in
            Self.ranWakeStatuses.contains(event.status ?? "")
                && (event.requestedAt.flatMap(Self.date).map { $0 > handoff.since } ?? false)
        }) {
            return .settled
        }
        return .held("seen before the app last stopped watching; not waking")
    }

    /// La tarjeta de un despertar que falló, mientras el agente siga sin ponerse en camino. Si no se puede leer
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
        let attemptedAt = attempt.at.addingTimeInterval(clockOffset[company.id] ?? 0)
        do {
            let runs = try await liveRuns(on: attempt.issueId)
            if runs.contains(where: { $0.agentId == attempt.agentId }) {
                onItsWay = true
            } else {
                onItsWay = try await wakes(of: attempt.agentId, on: attempt.issueId).contains { event in
                    guard let requested = event.requestedAt.flatMap(Self.date), requested > attemptedAt else { return false }
                    return Self.ranWakeStatuses.contains(event.status ?? "") || Self.onItsWay(event, liveRuns: runs)
                }
            }
        } catch {
            note(key, attempt.identifier ?? attempt.issueId, "couldn't read \(error.path): \(error.detail); the card stays")
        }
        if onItsWay {
            var recovered = attempt
            recovered.outcome = .recovered
            record(recovered, for: key)
            log.notice("\(attempt.identifier ?? attempt.issueId, privacy: .public): the agent is on its way, card dropped")
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
            id: "dispatch-handoff-wake:\(key)",
            issueId: attempt.issueId,
            identifier: attempt.identifier,
            title: attempt.title,
            agentId: attempt.agentId,
            agentName: attempt.agentName,
            issuePrefix: issuePrefix,
            whyNow: String(localized: "Paperclip didn’t wake up the agent it handed this task to."),
            text: attempt.agentName.map {
                String(localized: "It went to \($0), but Paperclip didn’t wake it up, and the app’s automatic wake-up didn’t work either.")
            } ?? String(localized: "It went to an agent, but Paperclip didn’t wake it up, and the app’s automatic wake-up didn’t work either.")
        )
    }

    /// Un traspaso que no se pudo comprobar: no se despierta a nadie y, pasado el margen, va la tarjeta que lo
    /// dice, una vez por traspaso. Un fallo de red o un 5xx espera a la revisión siguiente.
    private func unverifiedCard(
        _ handoff: Pending,
        _ problem: ReadProblem,
        agentKnown: Bool,
        issue: ListedIssue,
        company: PaperclipCompany,
        decisions: [AttentionItem],
        now: Date
    ) async -> AttentionItem? {
        let key = handoff.key
        note(key, issue, "couldn't read \(problem.path): \(problem.detail)" + (problem.transient ? " (may be temporary)" : ""))
        // La tarjeta que ya se muestra sigue igual: lo que no se pudo leer ahora no arma otra.
        if unverified[key] == nil {
            if problem.transient {
                transientFailures[key, default: 0] += 1
                guard transientFailures[key, default: 0] >= Self.transientFailuresForCard else { return nil }
            }
            // El nombre, para el texto: con el lector de siempre, porque puede ser justo lo que no se pudo leer.
            let agentId = agentKnown ? handoff.agentId : nil
            var name: String?
            if let agentId { name = await resolver.agentName(agentId) }
            unverified[key] = Unverified(
                at: now, showing: true, companyId: company.id, issueId: handoff.issueId,
                assigneeAgentId: handoff.agentId, seenAt: handoff.seenAt, since: handoff.since, agentId: agentId,
                agentName: name, identifier: issue.identifier, title: issue.title
            )
            saveUnverified()
            log.notice("\(issue.identifier ?? issue.id, privacy: .public): couldn't check the agent, card sent")
        }
        return showingUnverifiedCard(handoff, company: company, decisions: decisions)
    }

    /// La tarjeta de «no se pudo comprobar» de un traspaso, si sigue a la vista y Decisions no la muestra ya.
    private func showingUnverifiedCard(
        _ handoff: Pending,
        company: PaperclipCompany,
        decisions: [AttentionItem]
    ) -> AttentionItem? {
        // Una sola vez por traspaso: la que ya se retiró no vuelve.
        guard let entry = unverified[handoff.key], entry.showing else { return nil }
        // Decisions ya muestra esa tarea trabada con el mismo agente (o con cualquiera, si no se sabe quién está a
        // cargo).
        if decisions.contains(where: { item in
            item.wakeTarget?.issueId == handoff.issueId && (entry.agentId == nil || item.wakeTarget?.agentId == entry.agentId)
        }) {
            return nil
        }
        return Self.unverifiedItem(entry, key: handoff.key, issuePrefix: company.issuePrefix)
    }

    /// La tarjeta de un traspaso que no se pudo comprobar: no afirma lo que no se leyó, y lleva el botón solo si
    /// se sabe quién está a cargo.
    static func unverifiedItem(_ entry: Unverified, key: String, issuePrefix: String?) -> AttentionItem? {
        card(
            id: "dispatch-handoff-unverified:\(key)",
            issueId: entry.issueId,
            identifier: entry.identifier,
            title: entry.title,
            agentId: entry.agentId,
            agentName: entry.agentName,
            issuePrefix: issuePrefix,
            whyNow: String(localized: "The app couldn’t check whether the agent in charge is on its way."),
            text: entry.agentName.map {
                String(localized: "It went to \($0), but the app couldn’t check whether it’s on its way: Paperclip’s answer couldn’t be read. Check the task in Paperclip.")
            } ?? String(localized: "The app couldn’t check whether the agent in charge of this task is on its way: Paperclip’s answer couldn’t be read. Check the task in Paperclip.")
        )
    }

    /// Retira las tarjetas de una tarea, salvo las del traspaso `except`: son de un traspaso anterior.
    private func retireCards(issueId: String, except key: String) {
        var changed = false
        for (other, attempt) in attempts where attempt.issueId == issueId && attempt.showsCard && other != key {
            attempts[other]?.outcome = .recovered
            changed = true
        }
        if changed { save() }
        for (other, entry) in unverified where entry.issueId == issueId && entry.showing && other != key {
            retireUnverified(key: other, reason: "a new handoff")
        }
    }

    /// Retira la tarjeta de «no se pudo comprobar» de un traspaso: ya se puede leer, o ya no hace falta. No vuelve.
    private func retireUnverified(key: String, reason: String = "can read the task again") {
        guard let entry = unverified[key], entry.showing else { return }
        unverified[key]?.showing = false
        saveUnverified()
        log.notice("\(entry.identifier ?? entry.issueId, privacy: .public): \(reason, privacy: .public), card dropped")
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

    /// Las tareas de la company en los estados de trabajo, con todas sus páginas (por id, de menor a mayor).
    /// También la hora de Paperclip al leer la primera página.
    private func openIssues(of company: PaperclipCompany) async throws(ReadProblem) -> ([ListedIssue], Date?) {
        let path = "api/companies/\(company.id)/issues"
        var issues: [ListedIssue] = []
        var unreadable = 0
        var after: String?
        var serverDate: Date?
        for _ in 0..<Self.maxPages {
            var query = [
                URLQueryItem(name: "status", value: Self.workStatuses.joined(separator: ",")),
                URLQueryItem(name: "sortField", value: "id"),
                URLQueryItem(name: "sortDir", value: "asc"),
                URLQueryItem(name: "limit", value: String(Self.pageLimit)),
            ]
            if let after { query.append(URLQueryItem(name: "afterId", value: after)) }
            let (page, date): ([Lossy<ListedIssue>], Date?) = try await fetch(path, query: query)
            if after == nil { serverDate = date }
            let read = page.compactMap(\.value)
            unreadable += page.count - read.count
            issues += read
            guard page.count >= Self.pageLimit else {
                noteList(company, Self.listProblem(issues, unreadable: unreadable))
                return (issues, serverDate)
            }
            // Sin una tarea legible en la página no se puede pedir la siguiente.
            guard let last = read.last?.id, last != after else {
                throw ReadProblem(path: path, detail: "couldn't read the ids of a page", transient: false)
            }
            after = last
        }
        throw ReadProblem(path: path, detail: "more than \(Self.maxPages) pages", transient: false)
    }

    /// Lo que no se pudo leer de la lista, para el registro. `nil`: nada.
    private static func listProblem(_ issues: [ListedIssue], unreadable: Int) -> String? {
        var missing: [String] = []
        if issues.contains(where: { $0.status == nil }) { missing.append("status") }
        if issues.contains(where: { !$0.assigneeKnown }) { missing.append("assigneeAgentId") }
        if issues.contains(where: { $0.statusVersion == nil }) { missing.append("statusVersion") }
        if issues.contains(where: { !$0.activeRunKnown }) { missing.append("activeRun") }
        var parts: [String] = []
        if unreadable > 0 { parts.append("couldn't read \(unreadable) of the open tasks") }
        if !missing.isEmpty { parts.append("open tasks without a readable " + missing.joined(separator: ", ")) }
        return parts.isEmpty ? nil : parts.joined(separator: "; ")
    }

    /// Si un despertar pendiente va a llevar al agente a la tarea. Uno diferido (`deferred_issue_execution`)
    /// espera a que termine la corrida que tiene la tarea: sin ninguna corrida en ella, no va a salir solo.
    private static func onItsWay(_ event: WakeEvent, liveRuns: [LiveRun]) -> Bool {
        guard let status = event.status, pendingWakeStatuses.contains(status) else { return false }
        return status != "deferred_issue_execution" || !liveRuns.isEmpty
    }

    /// Las corridas en cola o en curso de la tarea. Falla si alguna no se puede leer: así «sin corridas» no se
    /// confunde con «no se pudieron leer».
    private func liveRuns(on issueId: String) async throws(ReadProblem) -> [LiveRun] {
        try await read("api/issues/\(issueId)/live-runs")
    }

    /// Los despertares de un agente en una tarea. Falla si algún evento no se puede leer o si un despertar viene
    /// sin el id de su agente (así no se sabe de quién es), y si uno del agente trae un estado que la app no
    /// conoce.
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
        try await fetch(path, query: query).0
    }

    /// Como `read`, con la hora de Paperclip en esa respuesta.
    private func fetch<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws(ReadProblem) -> (T, Date?) {
        do {
            return try await api.getWithServerDate(path, query: query)
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
        // Lo de la memoria, solo de lo que todavía se mira.
        let live = Set(pending.values.map(\.key)).union(attempts.filter { $0.value.showsCard }.keys)
        lastDecision = lastDecision.filter { live.contains($0.key) }
        transientFailures = transientFailures.filter { live.contains($0.key) }
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
    private func note(_ key: String, _ issue: ListedIssue, _ decision: String) {
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

    /// Una tarea de la lista, leída campo por campo: solo el `id` es obligatorio. Una tarea sin un estado o un
    /// asignado legibles no se usa para ver traspasos (`readable`).
    private struct ListedIssue: Decodable {
        let id: String
        let identifier: String?
        let title: String?
        /// Solo un estado que la app conoce.
        let status: String?
        let assigneeAgentId: String?
        /// Si la lista dice quién la tiene (aunque sea `null`: una persona o nadie).
        let assigneeKnown: Bool
        let statusVersion: Int?
        /// La corrida que tiene la tarea ahora, si se pudo leer.
        let activeRun: ActiveRun?
        let activeRunKnown: Bool

        struct ActiveRun: Decodable {
            let agentId: String
            let status: String

            private enum CodingKeys: String, CodingKey { case agentId, status }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                agentId = try container.decode(String.self, forKey: .agentId)
                status = try container.decodeKnown(.status, in: HandoffWaker.liveRunStatuses)
            }
        }

        var readable: Bool { status != nil && assigneeKnown }

        /// `false` solo si se sabe que la tiene otro (o nadie); `true` si se sabe que es de este agente o si no
        /// se pudo leer.
        func isAssigned(to agentId: String) -> Bool { !assigneeKnown || assigneeAgentId == agentId }

        private enum CodingKeys: String, CodingKey {
            case id, identifier, title, status, assigneeAgentId, statusVersion, activeRun
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            identifier = try? container.decodeIfPresent(String.self, forKey: .identifier)
            title = try? container.decodeIfPresent(String.self, forKey: .title)
            status = (try? container.decodeKnown(.status, in: HandoffWaker.issueStatuses))
            // Un `null` se leyó bien (nadie, o una persona); `try?` no lo distingue de un error.
            let assignee = Result { try container.decodeIfPresent(String.self, forKey: .assigneeAgentId) }
            assigneeAgentId = (try? assignee.get()) ?? nil
            assigneeKnown = container.contains(.assigneeAgentId) && Self.succeeded(assignee)
            statusVersion = try? container.decodeIfPresent(Int.self, forKey: .statusVersion)
            let run = Result { try container.decodeIfPresent(ActiveRun.self, forKey: .activeRun) }
            activeRun = (try? run.get()) ?? nil
            activeRunKnown = container.contains(.activeRun) && Self.succeeded(run)
        }

        private static func succeeded<T>(_ result: Result<T, Error>) -> Bool {
            if case .success = result { return true }
            return false
        }
    }

    /// Una tarea leída sola, con su etapa (`executionPolicy` y `executionState`), campo por campo para saber qué
    /// no se pudo leer.
    private struct IssueDetail: Decodable {
        let status: String
        let assigneeAgentId: String?
        private let hasStages: Bool
        private let state: State?
        /// Lo que no se pudo leer de la etapa.
        private let stageProblem: String?

        private enum CodingKeys: String, CodingKey { case status, assigneeAgentId, executionPolicy, executionState }
        private enum PolicyKeys: String, CodingKey { case stages }

        struct State {
            let status: String?
            let participantType: String?
            let agentId: String?
            let problem: String?
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            status = try container.decodeKnown(.status, in: HandoffWaker.issueStatuses)
            assigneeAgentId = try container.decodeIfPresent(String.self, forKey: .assigneeAgentId)
            // Las dos claves vienen siempre, aunque sea en `null`: si falta una, la respuesta cambió.
            guard container.contains(.executionPolicy), container.contains(.executionState) else {
                hasStages = false
                state = nil
                stageProblem = "missing executionPolicy or executionState"
                return
            }
            if try container.decodeNil(forKey: .executionPolicy) {
                hasStages = false
                state = nil
                stageProblem = nil
                return
            }
            guard let policy = try? container.nestedContainer(keyedBy: PolicyKeys.self, forKey: .executionPolicy),
                  let stages = try? policy.decode([PresentValue].self, forKey: .stages)
            else {
                hasStages = false
                state = nil
                stageProblem = "unexpected executionPolicy.stages"
                return
            }
            hasStages = !stages.isEmpty
            if try container.decodeNil(forKey: .executionState) {
                state = nil
                stageProblem = nil
                return
            }
            state = try? container.decode(StateReader.self, forKey: .executionState).state
            stageProblem = state == nil ? "executionState is not an object" : nil
        }

        /// Solo en revisión importa la etapa: su participante tiene que ser el agente a cargo. Lo que no se pudo
        /// leer de ella, y si igual se sabe quién está a cargo (sin leer al participante, el botón no va).
        func problem(for agentId: String, path: String) -> (problem: ReadProblem, agentKnown: Bool)? {
            func unreadable(_ detail: String) -> (problem: ReadProblem, agentKnown: Bool) {
                (ReadProblem(path: path, detail: detail, transient: false), state?.agentId == agentId)
            }
            guard status == "in_review", assigneeAgentId == agentId else { return nil }
            if let stageProblem { return unreadable(stageProblem) }
            guard hasStages, let state else { return nil }
            guard let stageStatus = state.status else { return unreadable("missing executionState.status") }
            guard HandoffWaker.stageStatuses.contains(stageStatus) else {
                return unreadable("unknown executionState.status “\(stageStatus)”")
            }
            guard stageStatus == "pending" else { return nil }
            if state.participantType == "user" { return nil }
            if let problem = state.problem { return unreadable(problem) }
            guard state.agentId != nil else { return unreadable("missing currentParticipant.agentId") }
            return nil
        }

        /// En revisión con una etapa pendiente, por qué no hay que mirar si su participante no es el agente a
        /// cargo (p. ej. la revisa una persona). `nil`: sí es él, o no hay etapa pendiente.
        func notTheStageAgent(_ agentId: String) -> String? {
            guard status == "in_review", hasStages, let state, state.status == "pending" else { return nil }
            if state.participantType == "user" { return "a person reviews it" }
            return state.agentId == agentId ? nil : "not assigned to the stage’s agent"
        }

        /// `executionState`, sin fallar: lo que no se puede leer queda en `problem`.
        private struct StateReader: Decodable {
            let state: State

            private enum Keys: String, CodingKey { case status, currentParticipant }
            private enum ParticipantKeys: String, CodingKey { case type, agentId }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: Keys.self)
                let status = try? container.decode(String.self, forKey: .status)
                var type: String?
                var agentId: String?
                var problem: String?
                if let participant = try? container.nestedContainer(keyedBy: ParticipantKeys.self, forKey: .currentParticipant) {
                    type = try? participant.decode(String.self, forKey: .type)
                    if let type, !HandoffWaker.participantTypes.contains(type) {
                        problem = "unknown currentParticipant.type “\(type)”"
                    } else if type == nil {
                        problem = "missing currentParticipant.type"
                    } else if type == "agent" {
                        agentId = try? participant.decode(String.self, forKey: .agentId)
                    }
                } else if status == "pending" {
                    problem = "missing currentParticipant"
                }
                state = State(status: status, participantType: type, agentId: agentId, problem: problem)
            }
        }
    }

    private struct HandoffAgent: Decodable {
        let name: String?
        let status: String
        let pauseReason: String?
        let budgetMonthlyCents: Int?
        let spentMonthlyCents: Int?

        private enum CodingKeys: String, CodingKey { case name, status, pauseReason, budgetMonthlyCents, spentMonthlyCents }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try? container.decodeIfPresent(String.self, forKey: .name)
            status = try container.decodeKnown(.status, in: HandoffWaker.agentStatuses)
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
            status = try container.decodeKnown(.status, in: HandoffWaker.liveRunStatuses)
        }
    }

    private struct WakeDiagnostics: Decodable {
        let events: [WakeEvent]
    }

    /// Un evento de `diagnostics/wakes`. Un despertar trae su agente, su estado y cuándo se pidió; si no, la
    /// lista entera no se lee. Un estado desconocido o una fecha ilegible quedan en `problem`: solo importan si
    /// el despertar es del agente a cargo.
    private struct WakeEvent: Decodable {
        let kind: String
        let agentId: String?
        let status: String?
        let requestedAt: String?
        /// Por qué lo pidió o lo descartó Paperclip (`other` si no es uno de los suyos conocidos).
        let reason: String?
        let problem: String?

        private enum CodingKeys: String, CodingKey { case kind, agentId, status, requestedAt, reason }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            kind = try container.decodeKnown(.kind, in: HandoffWaker.wakeEventKinds)
            guard kind == "wake_request" else {
                agentId = nil
                status = nil
                requestedAt = nil
                reason = nil
                problem = nil
                return
            }
            let agentId = try container.decode(String.self, forKey: .agentId)
            let status = try container.decode(String.self, forKey: .status)
            let requested = try container.decode(String.self, forKey: .requestedAt)
            self.agentId = agentId
            self.status = status
            requestedAt = requested
            reason = try? container.decodeIfPresent(String.self, forKey: .reason)
            problem = if !HandoffWaker.wakeStatuses.contains(status) {
                "unknown status “\(status)” in a wake of \(agentId)"
            } else if HandoffWaker.date(requested) == nil {
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
struct HandoffWakeSection: View {
    @Bindable var preferences: Preferences

    private static let issueURL = URL(string: "https://github.com/paperclipai/paperclip/issues/18315")!

    var body: some View {
        Section {
            Toggle(isOn: $preferences.wakeMissedHandoffs) {
                Text("Wake up agents Paperclip forgets")
                Text("When a task goes to an agent (for review, back to whoever did it, or to someone new), Paperclip sometimes loses its wake-up, and the task sits with no one working on it. If \(Int(HandoffWaker.margin / 60)) minutes go by and that agent still isn’t on it, the app wakes it up, once.")
            }
        } header: {
            Text("Handoffs")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("It’s on by default because it’s a known Paperclip bug: without it, those tasks wait until someone notices. It only looks at handoffs it sees while it’s open and works quietly; only if the wake-up fails do you get the stuck-task notification with its button. It will go away once Paperclip fixes the bug.")
                    .settingsFootnote()
                Link("Paperclip issue #18315 on GitHub", destination: Self.issueURL)
                    .font(.footnote)
            }
        }
    }
}
