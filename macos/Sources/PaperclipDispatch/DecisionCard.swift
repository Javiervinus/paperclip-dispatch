import Foundation

/// Una tarjeta de Decisions que se contesta de a poco fuera de la página: un formulario de varias preguntas,
/// tareas sugeridas, casillas, veredictos por ítem o una decisión con campos. Lo marcado (`CardProgress`) se
/// guarda en la Mac y a Paperclip le llega todo junto con el botón final, para que el agente despierte una
/// sola vez.
struct DecisionCard: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Hashable, Sendable {
        /// `ask_user_questions` con más de una pregunta, o con varias respuestas.
        case form
        /// `suggest_tasks`.
        case tasks
        /// `request_checkbox_confirmation`.
        case checkboxes
        /// `request_item_verdicts`.
        case verdicts
        /// Una decisión con campos: los campos son preguntas de texto y la última pregunta, la opción.
        case decision
    }

    enum Verdict: String, Codable, Hashable, Sendable, CaseIterable {
        case approve, reject, `defer`
    }

    var kind: Kind
    /// En las de una tarea: la tarea y la interacción. En una decisión, `decisionId`.
    var issueId: String?
    var interactionId: String?
    var decisionId: String?

    /// Formulario y decisión: las preguntas, en orden.
    var questions: [Question] = []
    /// Tareas, casillas o ítems.
    var entries: [Entry] = []
    /// Tareas y casillas: lo marcado al empezar, igual que en la página.
    var initialSelection: [String] = []
    var minSelected = 0
    var maxSelected: Int?
    /// El botón final (el de la tarjeta, si trae uno).
    var acceptLabel: String?
    var rejectLabel: String?
    /// Si rechazar pide escribir algo, lo que se pregunta.
    var rejectAsks: String?
    /// Veredictos: los que permite la tarjeta y los que piden un motivo.
    var verdicts: [Verdict] = []
    var reasonOn: [Verdict] = []
    var reasonLabel: String?

    struct Question: Codable, Hashable, Sendable {
        enum Mode: String, Codable, Hashable, Sendable { case single, multi, text }

        var id: String
        var prompt: String
        var help: String?
        var mode: Mode
        var required: Bool
        /// En una de texto, la opción `freeText` que la representa (si hay; un campo de una decisión no tiene).
        var options: [Option]
        /// En una de texto: lo que se pide al escribir.
        var placeholder: String?
        var maxLength: Int?
    }

    struct Option: Codable, Hashable, Sendable {
        /// `nil`: «Otra respuesta», sin opción propia (el texto va solo).
        var id: String?
        var label: String
        var detail: String?
        /// Al elegirla se escribe un texto.
        var asksText: Bool
    }

    struct Entry: Codable, Hashable, Sendable {
        var id: String
        var title: String
        /// A quién va una tarea, o la descripción de una casilla o un ítem.
        var detail: String?
        /// Tareas: la madre (`parentClientKey`). Marcar una tarea marca a su madre; desmarcarla, a sus hijas.
        var parentId: String?
        /// Tareas que la página no muestra (`hiddenInPreview`): van con su madre.
        var hidden = false
        /// Veredictos: el que ya tiene en Paperclip, de un envío anterior, y su motivo.
        var resolved: Verdict?
        var resolvedReason: String?
    }

    /// Lo que se muestra numerado: todo menos las tareas ocultas.
    var visibleEntries: [Entry] { entries.filter { !$0.hidden } }

    /// La pregunta de la opción de una decisión con campos.
    static let decisionOptionId = "paperclip-dispatch-option"
}

/// Lo que se lleva marcado en una tarjeta. Se guarda con el mensaje, así que sobrevive a un reinicio.
struct CardProgress: Codable, Hashable, Sendable {
    /// Formulario: la pregunta en pantalla; `questions.count` es el resumen.
    var step = 0
    var answers: [String: Answer] = [:]
    /// Tareas y casillas: lo marcado.
    var selected: [String] = []
    /// Veredictos elegidos y todavía sin mandar.
    var picks: [String: Pick] = [:]
    /// Se llegó a la pregunta desde el resumen (✏️): al contestarla se vuelve ahí.
    var editing = false

    struct Answer: Codable, Hashable, Sendable {
        var optionIds: [String] = []
        /// Lo escrito (en una de texto, o en la opción que pide escribir).
        var text: String?
        /// Saltada (solo las opcionales).
        var skipped = false
        /// Se eligió «Otra respuesta» sin opción propia.
        var other = false

        var isEmpty: Bool { optionIds.isEmpty && !other && (text?.isEmpty ?? true) }
    }

    struct Pick: Codable, Hashable, Sendable {
        var verdict: DecisionCard.Verdict
        var reason: String?
    }

    init(_ card: DecisionCard) {
        selected = card.initialSelection
    }
}

/// Un texto que pidió un botón de una tarjeta.
enum CardTextRequest: Codable, Hashable, Sendable {
    /// La respuesta escrita de una pregunta, con la opción que la pidió (`nil` en un campo sin opción).
    case answer(questionId: String, option: Int?)
    case reject
    case reason(entryId: String, verdict: DecisionCard.Verdict)
}

// MARK: - Avanzar

extension DecisionCard {
    func isSelected(_ id: String, in progress: CardProgress) -> Bool { progress.selected.contains(id) }

    /// Marca o desmarca, como en la página: en las tareas, marcar suma a la madre (y a sus hijas ocultas) y
    /// desmarcar quita a las hijas.
    func toggle(_ id: String, in progress: inout CardProgress) {
        var selected = Set(progress.selected)
        let family = [id] + descendants(of: id)
        if selected.contains(id) {
            selected.subtract(family)
        } else {
            selected.formUnion(family)
            var parent = entries.first(where: { $0.id == id })?.parentId
            while let current = parent {
                selected.insert(current)
                parent = entries.first(where: { $0.id == current })?.parentId
            }
        }
        progress.selected = entries.map(\.id).filter(selected.contains)
    }

    private func descendants(of id: String) -> [String] {
        entries.filter { $0.parentId == id }.flatMap { [$0.id] + descendants(of: $0.id) }
    }

    /// Lo marcado que se ve: en las tareas no cuentan las ocultas, que van con su madre.
    func markedCount(_ progress: CardProgress) -> Int {
        let visible = Set(visibleEntries.map(\.id))
        return progress.selected.filter(visible.contains).count
    }

    /// Por qué no se puede mandar todavía lo marcado, o `nil` si se puede.
    func selectionProblem(_ progress: CardProgress) -> String? {
        let count = markedCount(progress)
        // Paperclip pide al menos una tarea; con solo ocultas se crearían tareas que no se vieron.
        if kind == .tasks { return count == 0 ? String(localized: "Mark at least one task.") : nil }
        if count < minSelected { return String(localized: "Mark at least \(minSelected).") }
        if let maxSelected, count > maxSelected { return String(localized: "Mark no more than \(maxSelected).") }
        return nil
    }

    /// La primera pregunta obligatoria sin contestar, si hay.
    func missingAnswer(_ progress: CardProgress) -> Int? {
        questions.indices.first { index in
            let question = questions[index]
            return question.required && (progress.answers[question.id]?.isEmpty ?? true)
        }
    }

    /// Después de contestar la pregunta en pantalla: la siguiente, o el resumen si se vino de ahí.
    func advance(_ progress: inout CardProgress) {
        if progress.editing {
            progress.step = questions.count
            progress.editing = false
        } else {
            progress.step = min(progress.step + 1, questions.count)
        }
    }
}

// MARK: - Mandar a Paperclip

extension DecisionCard {
    /// Un pedido a la API de Paperclip.
    struct Submission {
        let path: String
        let body: [String: Any]
    }

    /// Lo que manda el botón final, con todo lo marcado.
    func submission(_ progress: CardProgress) -> Submission? {
        switch kind {
        case .form:
            guard let issueId, let interactionId else { return nil }
            let answers: [[String: Any]] = questions.compactMap { question in
                guard let answer = progress.answers[question.id], !answer.skipped, !answer.isEmpty else { return nil }
                var entry: [String: Any] = ["questionId": question.id, "optionIds": answer.optionIds]
                if let text = answer.text, !text.isEmpty { entry["otherText"] = text }
                return entry
            }
            return Submission(path: "api/issues/\(issueId)/interactions/\(interactionId)/respond", body: ["answers": answers])
        case .tasks:
            guard let issueId, let interactionId else { return nil }
            return Submission(
                path: "api/issues/\(issueId)/interactions/\(interactionId)/accept",
                body: ["selectedClientKeys": progress.selected]
            )
        case .checkboxes:
            guard let issueId, let interactionId else { return nil }
            return Submission(
                path: "api/issues/\(issueId)/interactions/\(interactionId)/accept",
                body: ["selectedOptionIds": progress.selected]
            )
        case .verdicts:
            guard let issueId, let interactionId else { return nil }
            let verdicts: [[String: Any]] = entries.compactMap { entry in
                guard entry.resolved == nil, let pick = progress.picks[entry.id] else { return nil }
                var verdict: [String: Any] = ["id": entry.id, "verdict": pick.verdict.rawValue]
                if let reason = pick.reason, !reason.isEmpty { verdict["reason"] = reason }
                return verdict
            }
            return Submission(path: "api/issues/\(issueId)/interactions/\(interactionId)/verdicts", body: ["verdicts": verdicts])
        case .decision:
            guard let decisionId,
                  let optionId = progress.answers[Self.decisionOptionId]?.optionIds.first
            else { return nil }
            var values: [String: String] = [:]
            for question in questions where question.id != Self.decisionOptionId {
                if let answer = progress.answers[question.id], !answer.skipped, let text = answer.text, !text.isEmpty {
                    values[question.id] = text
                }
            }
            // La misma clave si se manda dos veces: Paperclip la aplica una sola vez.
            return Submission(
                path: "api/decisions/\(decisionId)/decide",
                body: [
                    "optionId": optionId,
                    "inputValues": values,
                    "idempotencyKey": "\(DecisionResolver.idempotencyPrefix):\(decisionId):\(optionId)",
                ]
            )
        }
    }

    /// El rechazo de las tareas sugeridas o de las casillas.
    func rejection(reason: String?) -> Submission? {
        guard kind == .tasks || kind == .checkboxes, let issueId, let interactionId else { return nil }
        return Submission(
            path: "api/issues/\(issueId)/interactions/\(interactionId)/reject",
            body: reason.flatMap { $0.isEmpty ? nil : ["reason": $0] } ?? [:]
        )
    }

    /// Los veredictos que se acaban de mandar ya quedan en Paperclip: pasan a «ya enviado».
    func settlingPicks(_ progress: inout CardProgress) -> DecisionCard {
        var card = self
        for index in card.entries.indices where card.entries[index].resolved == nil {
            if let pick = progress.picks[card.entries[index].id] {
                card.entries[index].resolved = pick.verdict
                card.entries[index].resolvedReason = pick.reason
            }
        }
        progress.picks = [:]
        return card
    }

    var allResolved: Bool { kind == .verdicts && entries.allSatisfy { $0.resolved != nil } }
}

// MARK: - Armarla con lo que dice Paperclip

extension DecisionCard {
    /// `respond` acepta hasta 20 respuestas: un formulario más largo se contesta en la página.
    static let maxAnswers = 20

    /// Un formulario. `nil` si trae algo que no se puede contestar fuera de la página: el formulario entero va
    /// en Paperclip, nunca a medias.
    static func form(issueId: String, interactionId: String, payload: InteractionPayload) -> DecisionCard? {
        guard let questions = payload.questions, !questions.isEmpty else {
            Unexpected.note(source(interactionId), "ask_user_questions without questions")
            return nil
        }
        guard questions.count <= maxAnswers else { return nil }
        let readable = questions.compactMap { question($0, interactionId: interactionId) }
        guard readable.count == questions.count else { return nil }
        var card = DecisionCard(kind: .form, issueId: issueId, interactionId: interactionId)
        card.questions = readable
        card.acceptLabel = payload.submitLabel
        return card
    }

    /// Una pregunta como la guarda Paperclip. Una de texto llega como una sola opción `freeText`; «Otra
    /// respuesta» (`allowOther`) solo se agrega si no hay ya una opción para escribir. `nil` (y una línea en el
    /// registro) si no tiene opciones o su `selectionMode` no es uno de los que conoce la app.
    static func question(_ wire: InteractionPayload.Question, interactionId: String) -> Question? {
        guard let mode = wire.selectionMode.flatMap(Question.Mode.init(rawValue:)), mode != .text else {
            Unexpected.note(source(interactionId), "question \(wire.id): unknown selectionMode \(wire.selectionMode ?? "null")")
            return nil
        }
        guard !wire.options.isEmpty else {
            Unexpected.note(source(interactionId), "question \(wire.id) has no options")
            return nil
        }
        let isText = wire.options.count == 1 && wire.options[0].freeText == true
        if isText {
            let option = wire.options[0]
            return Question(
                id: wire.id, prompt: wire.prompt, help: wire.helpText, mode: .text, required: wire.required ?? false,
                options: [Option(id: option.id, label: option.label, detail: nil, asksText: true)],
                placeholder: option.description
            )
        }
        var options = wire.options.map {
            Option(id: $0.id, label: $0.label, detail: $0.description, asksText: $0.freeText == true)
        }
        if wire.allowOther == true, !options.contains(where: \.asksText) {
            options.append(Option(id: nil, label: String(localized: "Other answer…"), detail: nil, asksText: true))
        }
        return Question(
            id: wire.id, prompt: wire.prompt, help: wire.helpText, mode: mode, required: wire.required ?? false, options: options
        )
    }

    /// Para el registro: de dónde salió la tarjeta.
    private static func source(_ interactionId: String) -> String { "interaction \(interactionId)" }

    /// Tareas sugeridas. `agentNames`, por id, para decir a quién va cada una.
    static func tasks(
        issueId: String,
        interactionId: String,
        payload: InteractionPayload,
        agentNames: [String: String]
    ) -> DecisionCard? {
        guard let tasks = payload.tasks, !tasks.isEmpty else {
            Unexpected.note(source(interactionId), "suggest_tasks without tasks")
            return nil
        }
        // Una clave repetida, o una madre que no está en la lista, no se puede marcar como en la página.
        let keys = Set(tasks.map(\.clientKey))
        guard keys.count == tasks.count, tasks.allSatisfy({ $0.parentClientKey.map(keys.contains) ?? true }) else {
            Unexpected.note(source(interactionId), "suggest_tasks with repeated or missing clientKey")
            return nil
        }
        var card = DecisionCard(kind: .tasks, issueId: issueId, interactionId: interactionId)
        card.entries = tasks.map { task in
            let assignee: String? = if let agentId = task.assigneeAgentId {
                String(localized: "for \(agentNames[agentId] ?? String(localized: "an agent"))")
            } else if task.assigneeUserId != nil {
                String(localized: "for a person")
            } else {
                String(localized: "unassigned")
            }
            return Entry(
                id: task.clientKey, title: task.title, detail: assignee, parentId: task.parentClientKey,
                hidden: task.hiddenInPreview ?? false
            )
        }
        guard !card.visibleEntries.isEmpty else { return nil }
        // La página empieza con todas marcadas.
        card.initialSelection = tasks.map(\.clientKey)
        return card
    }

    static func checkboxes(issueId: String, interactionId: String, payload: InteractionPayload) -> DecisionCard? {
        guard let options = payload.options, !options.isEmpty else {
            Unexpected.note(source(interactionId), "request_checkbox_confirmation without options")
            return nil
        }
        // Lo que no se puede cumplir (pedir más de las que hay, un máximo menor que el mínimo) va en la página.
        let minimum = payload.minSelected ?? 0
        guard Set(options.map(\.id)).count == options.count, (0...options.count).contains(minimum),
              payload.maxSelected.map({ $0 >= max(minimum, 1) }) ?? true
        else {
            Unexpected.note(source(interactionId), "request_checkbox_confirmation with repeated ids or impossible limits")
            return nil
        }
        var card = DecisionCard(kind: .checkboxes, issueId: issueId, interactionId: interactionId)
        card.entries = options.map { Entry(id: $0.id, title: $0.label, detail: $0.description) }
        let ids = Set(options.map(\.id))
        card.initialSelection = (payload.defaultSelectedOptionIds ?? []).filter(ids.contains)
        card.minSelected = payload.minSelected ?? 0
        card.maxSelected = payload.maxSelected
        card.acceptLabel = payload.acceptLabel
        card.rejectLabel = payload.rejectLabel
        if payload.rejectRequiresReason == true {
            card.rejectAsks = payload.rejectReasonLabel ?? payload.declineReasonPlaceholder ?? String(localized: "Why?")
        }
        return card
    }

    static func verdicts(
        issueId: String,
        interactionId: String,
        payload: InteractionPayload,
        result: InteractionResult?
    ) -> DecisionCard? {
        guard let items = payload.items, !items.isEmpty else {
            Unexpected.note(source(interactionId), "request_item_verdicts without items")
            return nil
        }
        // Un veredicto que la app no conoce (en la lista, en los que piden motivo o en uno ya mandado) dejaría la
        // tarjeta a medias: va en Paperclip.
        let names = (payload.verdicts ?? []) + (payload.requireReasonOn ?? []) + (result?.items ?? []).map(\.verdict)
        if let unknown = names.first(where: { Verdict(rawValue: $0) == nil }) {
            Unexpected.note(source(interactionId), "unknown verdict \(unknown)")
            return nil
        }
        guard Set(items.map(\.id)).count == items.count else {
            Unexpected.note(source(interactionId), "request_item_verdicts with repeated item ids")
            return nil
        }
        var card = DecisionCard(kind: .verdicts, issueId: issueId, interactionId: interactionId)
        let resolved = Dictionary(
            (result?.items ?? []).compactMap { item in Verdict(rawValue: item.verdict).map { (item.id, (verdict: $0, reason: item.reason)) } },
            uniquingKeysWith: { first, _ in first }
        )
        card.entries = items.map {
            Entry(id: $0.id, title: $0.label, detail: $0.description, resolved: resolved[$0.id]?.verdict, resolvedReason: resolved[$0.id]?.reason)
        }
        // Sin la lista, Paperclip usa aprobar y rechazar, y pide motivo al rechazar.
        card.verdicts = (payload.verdicts ?? ["approve", "reject"]).compactMap(Verdict.init(rawValue:))
        card.reasonOn = (payload.requireReasonOn ?? ["reject"]).compactMap(Verdict.init(rawValue:))
        card.reasonLabel = payload.reasonLabel
        guard card.verdicts.contains(.approve), card.verdicts.contains(.reject), !card.allResolved else { return nil }
        return card
    }

    /// Una decisión con campos: cada campo es una pregunta de texto y al final se elige la opción. `nil` si
    /// un campo no se llena con texto.
    static func decision(decisionId: String, inputs: [DecisionInput], options: [(id: String, label: String)]) -> DecisionCard? {
        guard !inputs.isEmpty, !options.isEmpty, inputs.allSatisfy(\.isText) else {
            Unexpected.note("decision \(decisionId)", "inputs that aren’t text, or no options")
            return nil
        }
        var card = DecisionCard(kind: .decision, decisionId: decisionId)
        card.questions = inputs.map {
            Question(
                id: $0.id, prompt: $0.label, help: nil, mode: .text, required: $0.required ?? false, options: [],
                placeholder: $0.placeholder, maxLength: $0.maxLength
            )
        }
        card.questions.append(Question(
            id: decisionOptionId, prompt: String(localized: "What do you decide?"), help: nil, mode: .single, required: true,
            options: options.map { Option(id: $0.id, label: $0.label, detail: nil, asksText: false) }
        ))
        return card
    }

    /// La tarjeta en texto simple, para explicarla.
    var brief: String {
        switch kind {
        case .form, .decision:
            questions.enumerated().map { index, question in
                let options = question.mode == .text
                    ? String(localized: "(written answer)")
                    : question.options.map { "“\($0.label)”" }.joined(separator: " / ")
                return "\(index + 1). \(question.prompt) \(options)"
            }.joined(separator: "\n")
        case .tasks, .checkboxes, .verdicts:
            visibleEntries.enumerated().map { index, entry in
                "\(index + 1). \(entry.title)" + (entry.detail.map { " (\($0))" } ?? "")
            }.joined(separator: "\n")
        }
    }
}

// MARK: - Lo que se lee de la API

extension DecisionCard {
    /// `payload` de una interacción, con lo que usan estas tarjetas.
    struct InteractionPayload: Decodable {
        let submitLabel: String?
        let questions: [Question]?
        let tasks: [SuggestedTask]?
        let options: [CheckboxOption]?
        let defaultSelectedOptionIds: [String]?
        let minSelected: Int?
        let maxSelected: Int?
        let acceptLabel: String?
        let rejectLabel: String?
        let rejectRequiresReason: Bool?
        let rejectReasonLabel: String?
        let declineReasonPlaceholder: String?
        let items: [Item]?
        let verdicts: [String]?
        let requireReasonOn: [String]?
        let reasonLabel: String?

        struct Question: Decodable {
            let id: String
            let prompt: String
            let helpText: String?
            let selectionMode: String?
            let required: Bool?
            let allowOther: Bool?
            let options: [Option]
        }

        struct Option: Decodable {
            let id: String
            let label: String
            let description: String?
            let freeText: Bool?
        }

        struct SuggestedTask: Decodable {
            let clientKey: String
            let parentClientKey: String?
            let title: String
            let assigneeAgentId: String?
            let assigneeUserId: String?
            let hiddenInPreview: Bool?
        }

        struct CheckboxOption: Decodable {
            let id: String
            let label: String
            let description: String?
        }

        struct Item: Decodable {
            let id: String
            let label: String
            let description: String?
        }
    }

    /// `result` de una interacción: los veredictos ya mandados.
    struct InteractionResult: Decodable {
        let items: [Item]?

        struct Item: Decodable {
            let id: String
            let verdict: String
            let reason: String?
        }
    }

    /// Un campo de una decisión. Hoy todos son de texto; si una versión trae otro tipo, la decisión queda con
    /// el enlace.
    struct DecisionInput: Decodable {
        let id: String
        let label: String
        let placeholder: String?
        let required: Bool?
        let maxLength: Int?
        let type: String?

        var isText: Bool { type == nil || type == "text" }
    }
}
