import SwiftUI

/// La flecha del gesto de atrás y adelante con Liquid Glass (`PaperclipWebView`): un círculo de vidrio que
/// entra desde el borde siguiendo a los dedos, en vez de deslizar la página. Al centro, a media altura.
struct SwipeIndicatorView: View {
    static let size: CGFloat = 44
    /// Cuánto se aleja del borde con el gesto completo.
    static let margin: CGFloat = 20

    /// De 0 a 1 hacia atrás (entra por la izquierda), de 0 a -1 hacia adelante (por la derecha).
    let amount: CGFloat

    var body: some View {
        GeometryReader { geometry in
            let progress = min(abs(amount), 1)
            let back = amount > 0
            let travel = (Self.size + Self.margin) * progress
            Image(systemName: back ? "chevron.backward" : "chevron.forward")
                .font(.title2.weight(.semibold))
                .frame(width: Self.size, height: Self.size)
                .glassEffect(.regular, in: .circle)
                .scaleEffect(0.7 + 0.3 * progress)
                .opacity(progress)
                .position(
                    x: back ? travel - Self.size / 2 : geometry.size.width - travel + Self.size / 2,
                    y: geometry.size.height / 2
                )
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
