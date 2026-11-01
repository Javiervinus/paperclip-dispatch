import AppKit

/// El ícono de la app dentro de la app, igual al del Dock y los avisos. En macOS 26 ese ícono no sigue al
/// modo oscuro: sigue a Ajustes del Sistema → Apariencia → Estilo de íconos y widgets («Predeterminado» es
/// siempre el claro; «Oscuro» puede cambiar con la apariencia). Por eso se le pide a macOS, que ya lo dibuja
/// según ese ajuste. build.sh exporta además las variantes clara y oscura, para los dibujos de ejemplo.
@MainActor
enum AppIcon {
    private static let light = Bundle.main.image(forResource: "AppIconLight")
    private static let dark = Bundle.main.image(forResource: "AppIconDark")
    /// El dibujo del ícono del sistema ocupa 824 de sus 1024 px; el resto es margen.
    private static let systemIconContent: CGFloat = 824.0 / 1024

    /// El de macOS, sin el margen transparente de los íconos del sistema: ocupa todo el cuadro en que se dibuja.
    static func image() -> NSImage {
        let system = NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
        return NSImage(size: system.size, flipped: false) { rect in
            let grown = rect.width / systemIconContent
            system.draw(in: rect.insetBy(dx: (rect.width - grown) / 2, dy: (rect.height - grown) / 2))
            return true
        }
    }

    /// Una variante fija, sin margen, para dibujos que no son el ícono de la app (la foto del bot de ejemplo).
    static func variant(dark isDark: Bool) -> NSImage {
        (isDark ? dark : light) ?? image()
    }

    /// Para AppKit, del tamaño dado.
    static func image(size: CGFloat) -> NSImage {
        let icon = image()
        icon.size = NSSize(width: size, height: size)
        return icon
    }
}
