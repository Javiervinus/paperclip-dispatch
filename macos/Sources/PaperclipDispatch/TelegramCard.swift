import Foundation

/// Cómo se ve y cómo avanza en Telegram una tarjeta de varios pasos (`DecisionCard`): un solo mensaje que se
/// edita con cada toque. Los títulos completos van numerados en el texto; los botones, con el número y el
/// principio del título. Cada botón manda `f:<key>:<paso>:<acción>[:…]`: el paso hace que un toque viejo (o
/// doble) de un formulario no conteste otra pregunta.
enum TelegramCard {
    /// Lo que deja Telegram en un mensaje: botones y caracteres (después de leer el HTML).
    static let maxButtons = 100
    static let maxLength = 4096
    /// Lo que se muestra de un texto escrito, para que el mensaje no se pase del límite.
    static let textPreview = 200
    /// El principio del título que va en un botón.
    private static let labelLength = 26
    /// Botones «✏️ N» por fila en el resumen.
    private static let editsPerRow = 5

    struct Button {
        let text: String
        let data: String
    }

    // MARK: - El mensaje

    /// Lo que va debajo del encabezado de la decisión.
    static func body(_ card: DecisionCard, _ progress: CardProgress) -> String {
        switch card.kind {
        case .form, .decision:
            progress.step < card.questions.count ? questionBody(card, progress) : summary(card, progress, hint: true)
        case .tasks, .checkboxes:
            selectionBody(card, progress)
        case .verdicts:
            verdictsBody(card, progress)
        }
    }

    private static func questionBody(_ card: DecisionCard, _ progress: CardProgress) -> String {
        let question = card.questions[progress.step]
        let answer = progress.answers[question.id]
        var header = "<b>" + String(localized: "Question \(progress.step + 1) of \(card.questions.count)") + "</b>"
        if !question.required { header += " · <i>" + String(localized: "optional") + "</i>" }
        var lines = [header, "<b>\(TelegramFormat.escape(question.prompt))</b>"]
        if let help = question.help, !help.isEmpty { lines.append("<i>\(TelegramFormat.escape(help))</i>") }
        switch question.mode {
        case .single, .multi:
            for (index, option) in question.options.enumerated() {
                var line = "\(index + 1). \(TelegramFormat.escape(option.label))"
                if question.mode == .multi { line = (isChosen(option, in: answer) ? "☑ " : "☐ ") + line }
                if let detail = option.detail, !detail.isEmpty { line += " — <i>\(TelegramFormat.escape(detail))</i>" }
                if option.asksText, isChosen(option, in: answer), let text = answer?.text {
                    line += "\n   ✍️ <i>\(TelegramFormat.escape(preview(text)))</i>"
                }
                lines.append(line)
            }
            if question.mode == .multi { lines.append("<i>" + String(localized: "Mark one or more, then tap Next.") + "</i>") }
        case .text:
            if let placeholder = question.placeholder, !placeholder.isEmpty {
                lines.append("<i>\(TelegramFormat.escape(placeholder))</i>")
            }
            if let text = answer?.text, !text.isEmpty {
                lines.append("✍️ <i>\(TelegramFormat.escape(preview(text)))</i>")
            } else {
                lines.append("<i>" + String(localized: "Tap “Write your answer” and send it as a message.") + "</i>")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Todas las respuestas. `hint`: con la ayuda para corregir (en el resumen, no en el recibo).
    private static func summary(_ card: DecisionCard, _ progress: CardProgress, hint: Bool) -> String {
        var lines = ["<b>" + String(localized: "Your answers") + "</b>"]
        for (index, question) in card.questions.enumerated() {
            lines.append("\(index + 1). <b>\(TelegramFormat.escape(question.prompt))</b>")
            lines.append("→ " + answerText(question, progress.answers[question.id]))
        }
        if hint { lines.append("<i>" + String(localized: "Tap ✏️ to change an answer, or send them all.") + "</i>") }
        return lines.joined(separator: "\n")
    }

    private static func answerText(_ question: DecisionCard.Question, _ answer: CardProgress.Answer?) -> String {
        guard let answer else { return "<i>" + String(localized: "No answer") + "</i>" }
        if answer.skipped { return "<i>" + String(localized: "Skipped") + "</i>" }
        let text = answer.text.flatMap { $0.isEmpty ? nil : TelegramFormat.escape(preview($0)) }
        if question.mode == .text { return text ?? "<i>" + String(localized: "No answer") + "</i>" }
        var labels = question.options.filter { $0.id != nil && answer.optionIds.contains($0.id!) }.map(\.label)
        if answer.other { labels.append(String(localized: "Other answer")) }
        guard !labels.isEmpty else { return "<i>" + String(localized: "No answer") + "</i>" }
        return TelegramFormat.escape(labels.joined(separator: ", ")) + (text.map { ": <i>\($0)</i>" } ?? "")
    }

    private static func selectionBody(_ card: DecisionCard, _ progress: CardProgress) -> String {
        var lines = ["<b>" + (card.kind == .tasks
            ? String(localized: "Mark the tasks to create")
            : String(localized: "Mark your choices")) + "</b>"]
        if let rule = selectionRule(card) { lines.append("<i>\(rule)</i>") }
        for (index, entry) in card.visibleEntries.enumerated() {
            var line = (card.isSelected(entry.id, in: progress) ? "☑ " : "☐ ") + "\(index + 1). \(TelegramFormat.escape(entry.title))"
            if let detail = entry.detail, !detail.isEmpty { line += " · <i>\(TelegramFormat.escape(detail))</i>" }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    private static func selectionRule(_ card: DecisionCard) -> String? {
        guard card.kind == .checkboxes else { return nil }
        let min = card.minSelected
        return switch card.maxSelected {
        case let max? where min > 0 && min == max: String(localized: "Mark exactly \(min).")
        case let max? where min > 0: String(localized: "Mark between \(min) and \(max).")
        case let max?: String(localized: "Mark up to \(max).")
        case nil where min > 0: String(localized: "Mark at least \(min).")
        case nil: nil
        }
    }

    /// `final`: el recibo, después de mandar todos.
    private static func verdictsBody(_ card: DecisionCard, _ progress: CardProgress, final: Bool = false) -> String {
        var lines = final ? [] : ["<b>" + String(localized: "Give each item a verdict") + "</b>"]
        for (index, entry) in card.entries.enumerated() {
            var line = "\(index + 1). <b>\(TelegramFormat.escape(entry.title))</b>"
            if let detail = entry.detail, !detail.isEmpty { line += " — <i>\(TelegramFormat.escape(detail))</i>" }
            lines.append(line)
            if let resolved = entry.resolved {
                var verdict = "→ \(mark(resolved)) " + (final ? verdictName(resolved) : String(localized: "\(verdictName(resolved)) (already sent)"))
                if let reason = entry.resolvedReason, !reason.isEmpty { verdict += ": <i>\(TelegramFormat.escape(preview(reason)))</i>" }
                lines.append(verdict)
            } else if let pick = progress.picks[entry.id] {
                var verdict = "→ \(mark(pick.verdict)) \(verdictName(pick.verdict))"
                if let reason = pick.reason, !reason.isEmpty { verdict += ": <i>\(TelegramFormat.escape(preview(reason)))</i>" }
                lines.append(verdict)
            } else {
                lines.append("→ <i>" + String(localized: "No verdict yet") + "</i>")
            }
        }
        if card.entries.contains(where: { $0.resolved == nil }) {
            lines.append("<i>" + String(localized: "The ones without a verdict stay pending.") + "</i>")
        }
        return lines.joined(separator: "\n")
    }

    /// Lo que queda en el mensaje después de mandarla.
    static func receipt(_ card: DecisionCard, _ progress: CardProgress) -> String {
        let title = "✅ <b>" + String(localized: "Sent to Paperclip.") + "</b>"
        switch card.kind {
        case .form, .decision:
            return title + "\n" + summary(card, progress, hint: false)
        case .tasks, .checkboxes:
            let chosen = card.visibleEntries.enumerated().filter { card.isSelected($0.element.id, in: progress) }
            let header = card.kind == .tasks ? String(localized: "Tasks to create:") : String(localized: "You marked:")
            let lines = chosen.map { "☑ \($0.offset + 1). \(TelegramFormat.escape($0.element.title))" }
            return title + "\n" + header + "\n" + (lines.isEmpty ? "<i>" + String(localized: "None") + "</i>" : lines.joined(separator: "\n"))
        case .verdicts:
            return title + "\n" + verdictsBody(card, progress, final: true)
        }
    }

    static func rejected(_ card: DecisionCard, reason: String?) -> String {
        let label = TelegramFormat.escape(card.rejectLabel ?? String(localized: "Reject"))
        var html = "❌ <b>" + String(localized: "You rejected it: \(label)") + "</b>"
        if let reason, !reason.isEmpty { html += "\n<i>\(TelegramFormat.escape(preview(reason)))</i>" }
        return html
    }

    // MARK: - Los botones

    static func buttons(_ card: DecisionCard, _ progress: CardProgress, key: Int) -> [[Button]] {
        let prefix = "f:\(key):\(progress.step):"
        func button(_ text: String, _ action: String) -> Button { Button(text: text, data: prefix + action) }
        switch card.kind {
        case .form, .decision:
            guard progress.step < card.questions.count else {
                let edits = card.questions.indices.map { button("✏️ \($0 + 1)", "x:\($0)") }
                let rows = stride(from: 0, to: edits.count, by: editsPerRow).map { Array(edits[$0..<min($0 + editsPerRow, edits.count)]) }
                return rows + [[button("📨 " + (card.acceptLabel ?? String(localized: "Send")), "go")]]
            }
            let question = card.questions[progress.step]
            let answer = progress.answers[question.id]
            var rows: [[Button]]
            switch question.mode {
            case .single, .multi:
                rows = question.options.enumerated().map { index, option in
                    var text = "\(index + 1). \(short(option.label))"
                    if question.mode == .multi { text = (isChosen(option, in: answer) ? "☑ " : "☐ ") + text }
                    if option.asksText { text += " ✍️" }
                    return [button(text, "o:\(index)")]
                }
            case .text:
                rows = [[button(DecisionResolver.writeAnswerLabel, "o:0")]]
            }
            var navigation: [Button] = []
            if !question.required { navigation.append(button(String(localized: "Skip"), "s")) }
            if question.mode == .multi || !(answer?.isEmpty ?? true) {
                navigation.append(button(String(localized: "Next") + " →", "n"))
            }
            if !navigation.isEmpty { rows.append(navigation) }
            return rows
        case .tasks, .checkboxes:
            var rows = card.visibleEntries.enumerated().map { index, entry in
                [button((card.isSelected(entry.id, in: progress) ? "☑ " : "☐ ") + "\(index + 1). \(short(entry.title))", "t:\(index)")]
            }
            let count = card.markedCount(progress)
            let accept = card.kind == .tasks
                ? String(localized: "Create the marked ones (\(count))")
                : "\(card.acceptLabel ?? String(localized: "Confirm selection")) (\(count))"
            rows.append([button("✅ " + accept, "go"), button("❌ " + (card.rejectLabel ?? String(localized: "Reject")), "r")])
            return rows
        case .verdicts:
            var rows: [[Button]] = card.entries.enumerated().compactMap { index, entry in
                guard entry.resolved == nil else { return nil }
                let chosen = progress.picks[entry.id]?.verdict
                return card.verdicts.map { verdict in
                    var text = mark(verdict)
                    if verdict == .approve { text = "\(index + 1) " + text }
                    if chosen == verdict { text = "[\(text)]" }
                    return button(text, "v:\(index):\(verdict.code)")
                }
            }
            rows.append([button("📨 " + String(localized: "Send verdicts (\(progress.picks.count))"), "go")])
            return rows
        }
    }

    // MARK: - Qué hace cada botón

    enum Tap {
        /// Cambió lo marcado (o el paso): se vuelve a dibujar.
        case updated
        /// No cambió nada; lo que se contesta al toque, si algo.
        case unchanged(String?)
        /// No se puede todavía, y por qué. `progress` puede haber cambiado (p. ej. vuelve a la que falta).
        case alert(String)
        /// Hay que escribir algo: lo que se pide y lo que se pregunta.
        case askText(CardTextRequest, title: String, asks: String)
        case submit
        /// Rechazar; si pide un motivo, lo que se pregunta.
        case reject(asks: String?)
    }

    /// `action`: lo que va después de `f:<key>:` en el botón.
    static func tap(_ action: [Substring], card: DecisionCard, progress: inout CardProgress) -> Tap {
        guard let step = action.first.flatMap({ Int($0) }), action.count >= 2 else { return .unchanged(nil) }
        let op = action[1]
        let args = action.dropFirst(2).compactMap { Int($0) }
        let stale = Tap.unchanged(String(localized: "That button is out of date."))
        switch card.kind {
        case .form, .decision:
            guard step == progress.step else { return stale }
            return formTap(op, args: args, card: card, progress: &progress)
        case .tasks, .checkboxes:
            switch op {
            case "t":
                guard let index = args.first, card.visibleEntries.indices.contains(index) else { return stale }
                card.toggle(card.visibleEntries[index].id, in: &progress)
                return .updated
            case "go":
                return card.selectionProblem(progress).map(Tap.alert) ?? .submit
            case "r":
                return .reject(asks: card.rejectAsks)
            default:
                return stale
            }
        case .verdicts:
            switch op {
            case "v":
                guard let index = args.first, card.entries.indices.contains(index), card.entries[index].resolved == nil,
                      let verdict = action.last.flatMap({ DecisionCard.Verdict(code: $0) }), card.verdicts.contains(verdict)
                else { return stale }
                let entry = card.entries[index]
                if progress.picks[entry.id]?.verdict == verdict {
                    progress.picks[entry.id] = nil
                    return .updated
                }
                if card.reasonOn.contains(verdict) {
                    return .askText(
                        .reason(entryId: entry.id, verdict: verdict),
                        title: "\(index + 1). \(entry.title) · \(verdictName(verdict))",
                        asks: card.reasonLabel ?? String(localized: "Why?")
                    )
                }
                progress.picks[entry.id] = CardProgress.Pick(verdict: verdict)
                return .updated
            case "go":
                return progress.picks.isEmpty ? .alert(String(localized: "Give at least one verdict.")) : .submit
            default:
                return stale
            }
        }
    }

    private static func formTap(_ op: Substring, args: [Int], card: DecisionCard, progress: inout CardProgress) -> Tap {
        let stale = Tap.unchanged(String(localized: "That button is out of date."))
        guard progress.step < card.questions.count else {
            // El resumen.
            switch op {
            case "x":
                guard let index = args.first, card.questions.indices.contains(index) else { return stale }
                progress.step = index
                progress.editing = true
                return .updated
            case "go":
                if let missing = card.missingAnswer(progress) {
                    progress.step = missing
                    progress.editing = true
                    return .alert(String(localized: "Question \(missing + 1) needs an answer."))
                }
                return .submit
            default:
                return stale
            }
        }
        let question = card.questions[progress.step]
        let asks = question.placeholder.flatMap { $0.isEmpty ? nil : $0 } ?? String(localized: "Type your answer.")
        switch op {
        case "o":
            if question.mode == .text {
                return .askText(.answer(questionId: question.id, option: question.options.isEmpty ? nil : 0), title: question.prompt, asks: asks)
            }
            guard let index = args.first, question.options.indices.contains(index) else { return stale }
            let option = question.options[index]
            var answer = progress.answers[question.id] ?? CardProgress.Answer()
            answer.skipped = false
            if question.mode == .multi, isChosen(option, in: answer) {
                // Desmarcar; si pedía un texto, se va con ella.
                if let id = option.id { answer.optionIds.removeAll { $0 == id } } else { answer.other = false }
                if option.asksText { answer.text = nil }
                progress.answers[question.id] = answer
                return .updated
            }
            if option.asksText {
                return .askText(
                    .answer(questionId: question.id, option: index),
                    title: "\(question.prompt) · \(option.label)",
                    asks: option.detail.flatMap { $0.isEmpty ? nil : $0 } ?? asks
                )
            }
            guard let id = option.id else { return stale }
            if question.mode == .multi {
                answer.optionIds.append(id)
                progress.answers[question.id] = answer
            } else {
                progress.answers[question.id] = CardProgress.Answer(optionIds: [id])
                card.advance(&progress)
            }
            return .updated
        case "n":
            let empty = progress.answers[question.id]?.isEmpty ?? true
            if question.required, empty {
                return .alert(question.mode == .multi
                    ? String(localized: "Mark at least one answer.")
                    : String(localized: "This question needs an answer."))
            }
            // Una opcional de varias respuestas sin nada marcado cuenta como saltada.
            if empty { progress.answers[question.id] = CardProgress.Answer(skipped: true) }
            card.advance(&progress)
            return .updated
        case "s":
            guard !question.required else { return .alert(String(localized: "This question needs an answer.")) }
            progress.answers[question.id] = CardProgress.Answer(skipped: true)
            card.advance(&progress)
            return .updated
        default:
            return stale
        }
    }

    // MARK: - Lo que se escribe

    enum TextOutcome {
        case updated
        /// No vale (p. ej. es más largo de lo que acepta el campo): por qué.
        case invalid(String)
        case reject(String)
    }

    static func text(_ text: String, for request: CardTextRequest, card: DecisionCard, progress: inout CardProgress) -> TextOutcome {
        switch request {
        case .reject:
            return .reject(text)
        case let .reason(entryId, verdict):
            guard card.entries.contains(where: { $0.id == entryId && $0.resolved == nil }) else { return .updated }
            progress.picks[entryId] = CardProgress.Pick(verdict: verdict, reason: text)
            return .updated
        case let .answer(questionId, optionIndex):
            guard let index = card.questions.firstIndex(where: { $0.id == questionId }) else { return .updated }
            let question = card.questions[index]
            // Paperclip cuenta como JavaScript (unidades UTF-16).
            if let maxLength = question.maxLength, text.utf16.count > maxLength {
                return .invalid(String(localized: "It can be up to \(maxLength) characters; yours has \(text.utf16.count). Write it again."))
            }
            let option = optionIndex.flatMap { question.options.indices.contains($0) ? question.options[$0] : nil }
            var answer = question.mode == .multi ? progress.answers[question.id] ?? CardProgress.Answer() : CardProgress.Answer()
            answer.skipped = false
            answer.text = text
            if let id = option?.id {
                if !answer.optionIds.contains(id) { answer.optionIds.append(id) }
            } else if question.mode != .text {
                answer.other = true
            }
            progress.answers[question.id] = answer
            // Una de una respuesta (o de texto) pasa a la siguiente; en una de varias se sigue marcando.
            if question.mode != .multi, progress.step == index { card.advance(&progress) }
            return .updated
        }
    }

    // MARK: - Si cabe en un mensaje

    /// Si cada paso cabe en un mensaje de Telegram (con lo más largo que pueda tener), con el encabezado `base`
    /// y `extraButtons` («Explícamela», el enlace). Si no, la tarjeta va con el enlace a Paperclip.
    static func fits(_ card: DecisionCard, base: String, extraButtons: Int) -> Bool {
        let longText = String(repeating: "x", count: textPreview)
        var fullest = CardProgress(card)
        for question in card.questions {
            fullest.answers[question.id] = CardProgress.Answer(
                optionIds: question.options.compactMap(\.id),
                text: longText,
                other: question.options.contains { $0.id == nil }
            )
        }
        fullest.selected = card.entries.map(\.id)
        for entry in card.entries where entry.resolved == nil {
            fullest.picks[entry.id] = CardProgress.Pick(verdict: .reject, reason: longText)
        }
        let steps = card.kind == .form || card.kind == .decision ? Array(0...card.questions.count) : [0]
        return steps.allSatisfy { step in
            var progress = fullest
            progress.step = step
            let html = base + "\n\n" + body(card, progress)
            let buttons = buttons(card, progress, key: 0).reduce(0) { $0 + $1.count } + extraButtons
            return TelegramFormat.plain(html).utf16.count <= maxLength && buttons <= maxButtons
        } && TelegramFormat.plain(base + "\n\n" + receipt(card, fullest)).utf16.count <= maxLength
    }

    // MARK: - Ayudas

    private static func isChosen(_ option: DecisionCard.Option, in answer: CardProgress.Answer?) -> Bool {
        guard let answer else { return false }
        return option.id.map(answer.optionIds.contains) ?? answer.other
    }

    private static func short(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        return line.count > labelLength ? String(line.prefix(labelLength - 1)) + "…" : line
    }

    private static func preview(_ text: String) -> String {
        text.count > textPreview ? String(text.prefix(textPreview - 1)) + "…" : text
    }

    private static func mark(_ verdict: DecisionCard.Verdict) -> String {
        switch verdict {
        case .approve: "✅"
        case .reject: "❌"
        case .defer: "⏸"
        }
    }

    private static func verdictName(_ verdict: DecisionCard.Verdict) -> String {
        switch verdict {
        case .approve: String(localized: "Approve")
        case .reject: String(localized: "Reject")
        case .defer: String(localized: "Defer")
        }
    }
}

extension DecisionCard.Verdict {
    /// La letra que va en el botón.
    var code: String {
        switch self {
        case .approve: "a"
        case .reject: "r"
        case .defer: "d"
        }
    }

    init?(code: Substring) {
        guard let verdict = Self.allCases.first(where: { $0.code == code }) else { return nil }
        self = verdict
    }
}
