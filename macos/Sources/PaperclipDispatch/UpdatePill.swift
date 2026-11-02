import Observation
import SwiftUI

/// La píldora de versiones nuevas: lo que avisa macOS, pero dentro de la ventana, cuando se está mirando la app
/// o al volver a ella. Cuándo sale y cuándo se va lo decide `UpdateNotices`; aquí solo se dibuja.
@MainActor
@Observable
final class UpdatePill {
    struct Item: Equatable {
        let kind: UpdateNotices.Kind
        /// Lo primero, en negrita: «Salió Paperclip 2026.1101.0.»
        let lead: String
        let detail: String
        /// Para juntarla con otras en una sola línea: «Paperclip 2026.1101.0».
        let short: String
    }

    private(set) var items: [Item] = []
    private(set) var isVisible = false

    /// «Ver»: abre el panel de actualizaciones.
    @ObservationIgnored var onSee: (() -> Void)?
    /// La ×: más tarde, desde el botón de arriba.
    @ObservationIgnored var onDismiss: (() -> Void)?

    init() {}

    /// Para los ensayos: ya a la vista, con esas.
    init(previewing items: [Item]) {
        self.items = items
        isVisible = true
    }

    func show(_ items: [Item]) {
        self.items = items
        isVisible = !items.isEmpty
    }

    func hide() {
        isVisible = false
    }

    func see() { onSee?() }

    func dismiss() { onDismiss?() }

    /// Con una sola, su texto; con varias, una línea con todas.
    var message: (lead: String, detail: String) {
        guard items.count > 1 else { return (items.first?.lead ?? "", items.first?.detail ?? "") }
        return (String(localized: "New versions:"), items.map(\.short).formatted(.list(type: .and)))
    }

    /// Solo plugins: no apuran, como en el botón de arriba (la pieza gris).
    var onlyPlugins: Bool { items.allSatisfy { $0.kind == .plugins } }
}

/// La píldora, de vidrio, abajo y al centro de la ventana, como el recordatorio de avisos y en su mismo
/// lugar (nunca salen a la vez). Sin versiones nuevas no ocupa lugar.
struct UpdatePillView: View {
    let model: UpdatePill
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if model.isVisible, !model.items.isEmpty {
                capsule
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(NotificationNudgeView.shadowRoom)
        .animation(.spring(duration: 0.5, bounce: 0.25), value: model.isVisible)
        .animation(.smooth(duration: 0.3), value: model.items)
    }

    private var capsule: some View {
        let message = model.message
        return HStack(spacing: 12) {
            Image(systemName: model.onlyPlugins ? "puzzlepiece.extension.fill" : "arrow.down.circle.fill")
                .font(.title3)
                .foregroundStyle(model.onlyPlugins ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
                .accessibilityHidden(true)
            Text("\(Text(message.lead).bold()) \(message.detail)")
                .contentTransition(.opacity)
            Button("See", action: model.see)
                .buttonStyle(.glass)
            Button("Later", systemImage: "xmark", action: model.dismiss)
                .labelStyle(.iconOnly)
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .help("Later: they stay in the updates button")
        }
        .padding(.leading, 16)
        .padding(.trailing, 9)
        .padding(.vertical, 9)
        .fixedSize()
        .glassEffect(.regular, in: .capsule)
        .shadow(color: .black.opacity(0.25), radius: 18, y: 10)
    }
}

/// Lo que va abajo en la ventana: el recordatorio de avisos y la píldora de versiones nuevas, en el mismo
/// lugar. `UpdateNotices` espera a que el recordatorio se vaya, y el recordatorio, a que se vaya la píldora.
struct BottomPills: View {
    let nudge: NotificationNudge
    let updates: UpdatePill

    var body: some View {
        ZStack(alignment: .bottom) {
            NotificationNudgeView(model: nudge)
            UpdatePillView(model: updates)
        }
    }
}
