import AppKit
import WebKit

/// El WKWebView de la ventana. Con `tracksSwipes`, el gesto de atrás y adelante (dos dedos a lo ancho en el
/// trackpad) lo hace la app en vez de WebKit. Es para el modo Liquid Glass: ahí la página es transparente y
/// WebKit desliza una captura de la página anterior debajo de la actual, así que se ven las dos encimadas,
/// mientras el panel de vidrio (nativo) se queda quieto. Este gesto no mueve la página: informa el avance
/// (`onSwipe`, para la flecha que entra desde el borde) y, si se completa, navega.
final class PaperclipWebView: WKWebView {
    var tracksSwipes = false
    /// Lo que hay bajo el puntero todavía se desplaza a lo ancho hacia ese lado (lo informa glass.js): el
    /// gesto es de la página, como con el de WebKit, que solo navega desde el borde.
    var pageScrollsBack = false
    var pageScrollsForward = false
    /// El avance del gesto: de 0 a 1 hacia atrás, de 0 a -1 hacia adelante; `nil` cuando termina.
    var onSwipe: ((CGFloat?) -> Void)?

    override func scrollWheel(with event: NSEvent) {
        guard tracksSwipes, event.phase == .began, event.hasPreciseScrollingDeltas,
              NSEvent.isSwipeTrackingFromScrollEventsEnabled,
              abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
        else { return super.scrollWheel(with: event) }
        // Como en WebKit: desplazar hacia la izquierda más allá del borde (delta positivo) vuelve atrás.
        let back = event.scrollingDeltaX > 0
        guard back ? canGoBack && !pageScrollsBack : canGoForward && !pageScrollsForward
        else { return super.scrollWheel(with: event) }
        let sign: CGFloat = back ? 1 : -1
        var navigated = false
        // El sentido queda fijo desde el comienzo (.lockDirection): el avance se mide en valor absoluto.
        event.trackSwipeEvent(
            options: [.lockDirection, .clampGestureAmount],
            dampenAmountThresholdMin: -1,
            max: 1
        ) { [weak self] amount, phase, isComplete, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if phase == .ended, !navigated {
                    navigated = true
                    if back { self.goBack() } else { self.goForward() }
                }
                self.onSwipe?(isComplete ? nil : sign * abs(amount))
            }
        }
    }
}
