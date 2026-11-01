import SwiftUI

/// La flecha del gesto de atrás y adelante (`PaperclipWebView`): un círculo de vidrio que entra desde el
/// borde siguiendo a los dedos, en vez de deslizar la página. A media altura de la ventana.
struct SwipeIndicatorView: View {
    static let size: CGFloat = 44
    /// Cuánto se aleja del borde con el gesto completo.
    static let margin: CGFloat = 20

    let model: SwipeIndicator

    var body: some View {
        GeometryReader { geometry in
            if model.isVisible {
                arrow(in: geometry.size)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func arrow(in size: CGSize) -> some View {
        let progress = model.committed ? 1 : model.progress
        let travel = (Self.size + Self.margin) * progress
        return Image(systemName: model.back ? "chevron.backward" : "chevron.forward")
            .font(.title2.weight(.semibold))
            .frame(width: Self.size, height: Self.size)
            .glassEffect(.regular, in: .circle)
            .scaleEffect(model.committed ? 1.1 : 0.7 + 0.3 * progress)
            .opacity(model.committed ? 0 : progress)
            .position(
                x: model.back ? travel - Self.size / 2 : size.width - travel + Self.size / 2,
                y: size.height / 2
            )
    }
}
