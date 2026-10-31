import AppKit

/// Ensayos visuales, para revisar el diseño sin abrir nada en pantalla. Los corre `macos/snapshot.zsh`: abre
/// una segunda copia de la app con `-PaperclipSnapshot <settings|window>` y `-PaperclipSnapshotDirectory
/// <carpeta>`, que pone lo pedido en ventanas fuera de la pantalla y anota sus números en `windows.txt`. El
/// script las captura con `screencapture -l`, que sí dibuja el vidrio, y deja `captured` para que la copia
/// se cierre.
@MainActor
enum Snapshot {
    enum Kind: String {
        case settings, window
    }

    struct Window {
        let window: NSWindow
        let file: String
    }

    private static let kindKey = "PaperclipSnapshot"
    private static let directoryKey = "PaperclipSnapshotDirectory"
    private static let captureTimeout = 90

    static var requested: (Kind, URL)? {
        let defaults = UserDefaults.standard
        guard let kind = defaults.string(forKey: kindKey).flatMap(Kind.init),
              let path = defaults.string(forKey: directoryKey)
        else { return nil }
        return (kind, URL(fileURLWithPath: path, isDirectory: true))
    }

    /// Fuera de la pantalla: no tapa nada ni se lleva el foco.
    static func hide(_ window: NSWindow) {
        window.orderFrontRegardless()
        window.setFrameOrigin(NSPoint(x: -20_000, y: 0))
    }

    /// Anota las ventanas, espera a que el script las capture y las cierra.
    static func capture(_ windows: [Window], in directory: URL) async {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let manifest = windows.map { "\($0.window.windowNumber) \($0.file)" }.joined(separator: "\n")
        try? manifest.write(to: directory.appending(path: "windows.txt"), atomically: true, encoding: .utf8)
        let captured = directory.appending(path: "captured")
        for _ in 0..<captureTimeout where !FileManager.default.fileExists(atPath: captured.path) {
            try? await Task.sleep(for: .seconds(1))
        }
        windows.forEach { $0.window.orderOut(nil) }
    }
}

/// Ensayo de la ventana de Paperclip (`macos/snapshot.zsh window`): el modo normal y el de Liquid Glass, al
/// abrir y al cambiar de uno a otro con la página ya cargada, que es lo que hace el ajuste. Lleva un botón
/// de versión de muestra.
@MainActor
enum MainWindowSnapshot {
    private static let contentSize = NSSize(width: 1280, height: 800)
    private static let loadTime: Duration = .seconds(8)

    static func run(config: AppConfig, to directory: URL) async {
        let cases: [(file: String, startsWithGlass: Bool, switches: Bool)] = [
            ("normal", false, false),
            ("vidrio", true, false),
            ("normal-a-vidrio", false, true),
            ("vidrio-a-normal", true, true),
        ]
        var controllers: [(controller: MainWindowController, switches: Bool, glass: Bool)] = []
        var windows: [Snapshot.Window] = []
        for item in cases {
            let controller = MainWindowController(config: config, liquidGlass: item.startsWithGlass, remembersFrame: false)
            guard let window = controller.window else { continue }
            window.setContentSize(contentSize)
            controller.setUpdateButton(sampleButton(), visible: true)
            Snapshot.hide(window)
            controllers.append((controller, item.switches, item.startsWithGlass))
            windows.append(Snapshot.Window(window: window, file: "\(item.file).png"))
        }
        try? await Task.sleep(for: loadTime)
        for entry in controllers where entry.switches {
            entry.controller.setLiquidGlass(!entry.glass)
        }
        try? await Task.sleep(for: loadTime)
        await Snapshot.capture(windows, in: directory)
    }

    /// Como el de UpdateController, con la versión al día.
    private static func sampleButton() -> NSButton {
        let button = NSButton(title: "Al día · 2026.1023.0", target: nil, action: nil)
        button.controlSize = .large
        button.imagePosition = .imageLeading
        button.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(paletteColors: [.white, .systemGreen]))
        return button
    }
}
