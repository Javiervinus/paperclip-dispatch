import AppKit
import WebKit

/// El WKWebView de la ventana, con el gesto de atrás y adelante (dos dedos a lo ancho en el trackpad) hecho
/// por la app en vez de WebKit. El de WebKit desliza la página entera sobre una captura de la anterior:
/// la barra lateral de Paperclip, que nunca cambia, se iba con ella, y con Liquid Glass (página
/// transparente) además se veían las dos páginas encimadas. Este no mueve la página: informa el gesto
/// (`onSwipe`, para la flecha que entra desde el borde) y, si se completa, navega.
final class PaperclipWebView: WKWebView {
    enum SwipeUpdate {
        /// De 0 a 1 hacia atrás, de 0 a -1 hacia adelante, siguiendo a los dedos.
        case progress(CGFloat)
        /// Se completó y ya navegó: la flecha se va enseguida, sin esperar la animación de macOS.
        case committed
        /// Se soltó sin completarlo y macOS terminó de devolverlo a cero.
        case cancelled
    }

    /// Lo que hay bajo el puntero todavía se desplaza a lo ancho hacia ese lado (lo informa bridge.js): el
    /// gesto es de la página, como con el de WebKit, que solo navega desde el borde.
    var pageScrollsBack = false
    var pageScrollsForward = false
    var onSwipe: ((SwipeUpdate) -> Void)?

    override func scrollWheel(with event: NSEvent) {
        guard event.phase == .began, event.hasPreciseScrollingDeltas,
              NSEvent.isSwipeTrackingFromScrollEventsEnabled,
              abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
        else { return super.scrollWheel(with: event) }
        // Como en WebKit: desplazar hacia la izquierda más allá del borde (delta positivo) vuelve atrás.
        let back = event.scrollingDeltaX > 0
        guard back ? canGoBack && !pageScrollsBack : canGoForward && !pageScrollsForward
        else { return super.scrollWheel(with: event) }
        let sign: CGFloat = back ? 1 : -1
        var committed = false
        // El sentido queda fijo desde el comienzo (.lockDirection): el avance se mide en valor absoluto.
        event.trackSwipeEvent(
            options: [.lockDirection, .clampGestureAmount],
            dampenAmountThresholdMin: -1,
            max: 1
        ) { [weak self] amount, phase, isComplete, stop in
            MainActor.assumeIsolated {
                guard let self, !committed else { return }
                if phase == .ended {
                    // Al soltar (o con un gesto rápido) macOS ya decidió: se navega al momento y se deja de
                    // seguir la animación que lo lleva hasta el final, que va más lenta que la página.
                    committed = true
                    stop.pointee = true
                    if back { self.goBack() } else { self.goForward() }
                    self.onSwipe?(.committed)
                } else if isComplete {
                    self.onSwipe?(.cancelled)
                } else {
                    self.onSwipe?(.progress(sign * abs(amount)))
                }
            }
        }
    }
}
