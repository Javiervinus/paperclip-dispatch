import Observation
import SwiftUI

/// El estado de la flecha del gesto de atrás y adelante (`SwipeIndicatorView`), que lo actualiza
/// `PaperclipWebView`.
@MainActor
@Observable
final class SwipeIndicator {
    /// Lo que tarda en irse al completarse el gesto: va con el cambio de página.
    private static let commitAnimation: Animation = .easeOut(duration: 0.2)

    /// Hacia atrás entra por la izquierda; hacia adelante, por la derecha.
    private(set) var back = true
    /// De 0 a 1, siguiendo a los dedos.
    private(set) var progress: CGFloat = 0
    /// Se completó: termina de entrar mientras se desvanece.
    private(set) var committed = false
    /// Sin gesto no se dibuja nada.
    var isVisible: Bool { progress > 0 }
    /// Cuenta los gestos: lo que termina de uno no toca al siguiente.
    @ObservationIgnored private var gesture = 0

    func update(_ swipe: PaperclipWebView.SwipeUpdate) {
        switch swipe {
        case .progress(let amount):
            if committed { gesture += 1 }
            committed = false
            back = amount >= 0
            progress = min(abs(amount), 1)
        case .committed:
            let current = gesture
            withAnimation(Self.commitAnimation) {
                committed = true
            } completion: { [weak self] in
                guard let self, gesture == current else { return }
                progress = 0
            }
        case .cancelled:
            progress = 0
        }
    }
}
