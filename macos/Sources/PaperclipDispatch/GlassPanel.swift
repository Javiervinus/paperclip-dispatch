import AppKit

/// Un panel de Liquid Glass detrás de la página, donde layout.js dice que hay un panel de Paperclip (la barra
/// lateral o el de propiedades de una tarea): material translúcido de macOS con Liquid Glass
/// (NSGlassEffectView) encima. El vidrio va recortado al panel: su sombra hacia afuera, invisible en oscuro,
/// en claro agrisaría el margen.
@MainActor
final class GlassPanel {
    /// El borde de la ventana al que va pegado: al cambiar el ancho de la ventana, el panel lo sigue hasta
    /// el siguiente aviso de layout.js.
    enum Edge {
        case leading, trailing
    }

    private let edge: Edge
    private let backdrop = NSVisualEffectView()
    private let glass = NSGlassEffectView()
    /// Recorta el vidrio a su borde.
    private let clip = NSView()
    private var radius: CGFloat = -1

    init(edge: Edge) {
        self.edge = edge
        backdrop.material = .sidebar
        backdrop.blendingMode = .behindWindow
        backdrop.state = .followsWindowActiveState
        backdrop.isHidden = true
        glass.style = .regular
        clip.wantsLayer = true
        clip.layer?.masksToBounds = true
        clip.layer?.cornerCurve = .continuous
        clip.isHidden = true
        clip.addSubview(glass)
    }

    /// Justo debajo de la página.
    func install(in container: NSView, below page: NSView) {
        container.addSubview(backdrop, positioned: .below, relativeTo: page)
        container.addSubview(clip, positioned: .below, relativeTo: page)
    }

    /// Detrás de una ventana en pantalla completa solo queda el fondo de pantalla, que teñiría el panel (y
    /// aparece y desaparece al cambiar de escritorio): ahí el material toma el fondo de la propia ventana.
    func setBlendsWithinWindow(_ within: Bool) {
        backdrop.blendingMode = within ? .withinWindow : .behindWindow
    }

    /// Lo ubica, o lo esconde con `nil`.
    func place(_ frame: CGRect?, radius: CGFloat) {
        guard let frame, frame.width > 0, frame.height > 0 else {
            backdrop.isHidden = true
            clip.isHidden = true
            return
        }
        if radius != self.radius {
            self.radius = radius
            glass.cornerRadius = radius
            clip.layer?.cornerRadius = radius
            backdrop.maskImage = Self.roundedMask(radius: radius)
        }
        for view in [backdrop, clip] {
            view.frame = frame
            // Entre un aviso de layout.js y el siguiente, el panel sigue el alto de la ventana (y el borde
            // derecho, si va ahí). Recién ahora: con tamaño cero y alto flexible, macOS agranda la ventana 10
            // puntos cada vez que se abre.
            view.autoresizingMask = edge == .trailing ? [.height, .minXMargin] : [.height]
            view.isHidden = false
        }
        glass.frame = clip.bounds
        glass.autoresizingMask = [.width, .height]
    }

    /// Máscara de esquinas redondeadas para el material translúcido, que se estira sin deformar las esquinas.
    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}
