import AppKit

/// El ícono de la app dentro de la app, en la variante de la apariencia (clara u oscura), como lo muestra
/// el Dock. `NSApp.applicationIconImage` trae solo la clara, y con el margen transparente de los íconos de
/// macOS; build.sh exporta las dos variantes del documento de Icon Composer, sin margen.
@MainActor
enum AppIcon {
    private static let light = Bundle.main.image(forResource: "AppIconLight")
    private static let dark = Bundle.main.image(forResource: "AppIconDark")
    /// El dibujo del ícono del sistema ocupa 824 de sus 1024 px; el resto es margen.
    private static let systemIconContent: CGFloat = 824.0 / 1024

    /// La variante de esa apariencia, sin margen: ocupa todo el cuadro en que se dibuja.
    static func image(dark isDark: Bool) -> NSImage {
        if let light, let dark { return isDark ? dark : light }
        let system = NSApp.applicationIconImage ?? NSImage()
        return NSImage(size: system.size, flipped: false) { rect in
            let grown = rect.width / systemIconContent
            system.draw(in: rect.insetBy(dx: (rect.width - grown) / 2, dy: (rect.height - grown) / 2))
            return true
        }
    }

    /// Para AppKit: se dibuja con la variante de la apariencia del momento, también si cambia después.
    static func adaptive(size: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let isDark = NSAppearance.currentDrawing().bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            image(dark: isDark).draw(in: rect)
            return true
        }
    }
}
