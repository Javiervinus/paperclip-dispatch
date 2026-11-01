import SwiftUI

/// La píldora del recordatorio de avisos (`NotificationNudge`): de vidrio, abajo y al centro de la ventana.
/// No tapa la página ni bloquea nada; sin recordatorio no ocupa lugar.
struct NotificationNudgeView: View {
    /// Aire alrededor de la píldora para que la sombra no se corte en el borde de su vista.
    static let shadowRoom: CGFloat = 24

    let model: NotificationNudge
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if model.isVisible, let problem = model.problem {
                capsule(problem)
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(Self.shadowRoom)
        .animation(.spring(duration: 0.5, bounce: 0.25), value: model.isVisible)
        .animation(.smooth(duration: 0.3), value: model.confirmed)
    }

    private func capsule(_ problem: NotificationNudge.Problem) -> some View {
        HStack(spacing: 12) {
            Image(systemName: model.confirmed ? "checkmark.circle.fill" : "bell.slash.fill")
                .font(.title3)
                .foregroundStyle(model.confirmed ? .green : .orange)
                .contentTransition(.symbolEffect(.replace))
                .accessibilityHidden(true)
            message(problem)
                .contentTransition(.opacity)
            if !model.confirmed {
                Button(problem == .off ? "Activar" : "Ajustar", action: model.act)
                    .buttonStyle(.glassProminent)
                Button("Esconder por una semana", systemImage: "xmark", action: model.dismiss)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .help("Esconder por una semana")
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, model.confirmed ? 16 : 9)
        .padding(.vertical, model.confirmed ? 13 : 9)
        .fixedSize()
        .glassEffect(.regular, in: .capsule)
        .shadow(color: .black.opacity(0.25), radius: 18, y: 10)
    }

    private func message(_ problem: NotificationNudge.Problem) -> Text {
        let (lead, rest) = model.confirmed ? ("Avisos activados.", "Te avisamos cuando un agente te necesite.") : texts(problem)
        return Text("\(Text(lead).bold()) \(rest)")
    }

    private func texts(_ problem: NotificationNudge.Problem) -> (String, String) {
        switch problem {
        case .off: ("Los avisos están apagados:", "no te vas a enterar cuando un agente te necesite.")
        case .noBanners: ("Los avisos llegan sin banner:", "solo los verías en el Centro de notificaciones.")
        case .noBadge: ("Falta el número en el Dock:", "macOS no deja mostrar cuántas decisiones esperan.")
        }
    }
}
