import AppKit

/// Una ventana que los ensayos pueden dejar casi entera fuera de la pantalla y más alta que ella. Por
/// defecto macOS la acomoda: deja asomar unos 40 puntos y la achica al alto de la pantalla.
final class SnapshotableWindow: NSWindow {
    var keepsFrame = false

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        keepsFrame ? frameRect : super.constrainFrameRect(frameRect, to: screen)
    }
}

/// Ensayos visuales, para revisar el diseño sin tapar nada en pantalla. Los corre `macos/snapshot.zsh`: abre
/// una segunda copia de la app con `-PaperclipSnapshot <settings|window|page|welcome>` y
/// `-PaperclipSnapshotDirectory <carpeta>`, que pone lo pedido en ventanas fuera de la pantalla y anota sus
/// números en `windows.txt`. El script las captura con `screencapture -l`, que sí dibuja el vidrio, y deja
/// `captured` para que la copia se cierre.
///
/// Fuera de la pantalla las ventanas se ven inactivas (botones grises). Con `-PaperclipSnapshotActive YES`
/// (ACTIVE=1 en el script) se muestran de a una en el centro de la pantalla, al frente: para capturas de
/// muestra, cuando nadie está usando la Mac. Cada una se anota en `window-<n>.txt`; el script deja
/// `captured-<n>` y, al final, la app deja `done`.
@MainActor
enum Snapshot {
    enum Kind: String {
        case settings, window, page, welcome
    }

    struct Window {
        let window: NSWindow
        let file: String
    }

    private static let kindKey = "PaperclipSnapshot"
    private static let directoryKey = "PaperclipSnapshotDirectory"
    private static let activeKey = "PaperclipSnapshotActive"
    private static let captureTimeout = 90
    /// Lo que tarda una ventana recién puesta al frente en dibujarse como activa.
    private static let activeSettleTime: Duration = .seconds(1.5)

    /// Para ensayar sin dirección elegida: no responde nada ahí. No sirve un puerto de los que WebKit bloquea
    /// (como el 9): con esos no avisa que la carga falló.
    static let placeholderServerURL = URL(string: "http://127.0.0.1:65535")!

    static var active: Bool { UserDefaults.standard.bool(forKey: activeKey) }

    static var requested: (Kind, URL)? {
        let defaults = UserDefaults.standard
        guard let kind = defaults.string(forKey: kindKey).flatMap(Kind.init),
              let path = defaults.string(forKey: directoryKey)
        else { return nil }
        return (kind, URL(fileURLWithPath: path, isDirectory: true))
    }

    /// La versión de Paperclip instalada, como la ve la app.
    static func installedVersion() async -> UpdateController.Check? {
        let result = await Shell.run(["-c", UpdateController.checkCommand])
        return result.status == 0 ? UpdateController.decode(result.output) : nil
    }

    /// Como el botón de UpdateController, con la versión dada.
    static func versionButton(_ check: UpdateController.Check?) -> NSButton {
        let current = check?.currentVersion ?? "2026.1023.0"
        let available = check?.updateAvailable == true
        let button = NSButton(
            title: available ? "Actualizar a \(check?.targetVersion ?? "")" : "Al día · \(current)",
            target: nil,
            action: nil
        )
        button.controlSize = .large
        button.imagePosition = .imageLeading
        let symbol = NSImage(systemSymbolName: available ? "arrow.down.circle.fill" : "checkmark.circle.fill",
                             accessibilityDescription: nil)
        button.image = available ? symbol : symbol?.withSymbolConfiguration(.init(paletteColors: [.white, .systemGreen]))
        button.tintProminence = available ? .primary : .none
        return button
    }

    /// Fuera de la pantalla salvo un punto del borde, sin llevarse el foco, y del tamaño pedido. macOS solo
    /// captura ventanas que tocan una pantalla; con un punto basta y no se ve.
    static func hide(_ window: NSWindow, contentSize: NSSize? = nil) {
        (window as? SnapshotableWindow)?.keepsFrame = true
        if let contentSize { window.setContentSize(contentSize) }
        let screen = NSScreen.screens.first?.frame ?? .zero
        window.setFrameOrigin(NSPoint(x: screen.minX - window.frame.width + 1, y: screen.minY))
        window.orderFrontRegardless()
    }

    /// Anota las ventanas, espera a que el script las capture y las cierra.
    static func capture(_ windows: [Window], in directory: URL) async {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if active {
            await captureActive(windows, in: directory)
            return
        }
        let manifest = windows.map { "\($0.window.windowNumber) \($0.file)" }.joined(separator: "\n")
        try? manifest.write(to: directory.appending(path: "windows.txt"), atomically: true, encoding: .utf8)
        let captured = directory.appending(path: "captured")
        for _ in 0..<captureTimeout where !FileManager.default.fileExists(atPath: captured.path) {
            try? await Task.sleep(for: .seconds(1))
        }
        windows.forEach { $0.window.orderOut(nil) }
    }

    /// De a una, en el centro de la pantalla y al frente, para que se vean como la ventana en uso.
    private static func captureActive(_ windows: [Window], in directory: URL) async {
        windows.forEach { $0.window.orderOut(nil) }
        for (index, item) in windows.enumerated() {
            let window = item.window
            (window as? SnapshotableWindow)?.keepsFrame = false
            window.center()
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            try? await Task.sleep(for: activeSettleTime)
            let number = index + 1
            try? "\(window.windowNumber) \(item.file)"
                .write(to: directory.appending(path: "window-\(number).txt"), atomically: true, encoding: .utf8)
            let captured = directory.appending(path: "captured-\(number)")
            for _ in 0..<captureTimeout where !FileManager.default.fileExists(atPath: captured.path) {
                try? await Task.sleep(for: .seconds(1))
            }
            window.orderOut(nil)
        }
        try? Data().write(to: directory.appending(path: "done"))
    }
}

/// Ensayo de la bienvenida (`macos/snapshot.zsh welcome`): cada paso, en claro y en oscuro, con datos de
/// muestra (no busca ni enciende nada), y la ventana de Paperclip cuando no responde.
@MainActor
enum WelcomeSnapshot {
    private static let offlineContentSize = NSSize(width: 960, height: 620)
    /// Lo que tarda en fallar la carga de la dirección muerta y en mostrarse el aviso.
    private static let settleTime: Duration = .seconds(4)

    static func run(to directory: URL) async {
        let version = await Snapshot.installedVersion()?.currentVersion ?? "2026.1023.0"
        let local = LocalPaperclip(
            instanceId: "default",
            url: URL(string: "http://127.0.0.1:\(PaperclipLocator.defaultPort)")!,
            port: PaperclipLocator.defaultPort,
            hasService: true
        )
        let health = PaperclipHealth(status: "ok", deploymentMode: "local_trusted", version: version)
        let cases: [(file: String, make: () -> WelcomeModel)] = [
            ("encontrado", { WelcomeModel(mode: .firstRun, step: .found(local, health)) }),
            ("apagado", { WelcomeModel(mode: .firstRun, step: .stopped(local)) }),
            ("no-encontrado", { WelcomeModel(mode: .firstRun, step: .notFound) }),
            ("instalar", {
                let model = WelcomeModel(mode: .firstRun, step: .install)
                model.node = .ready("v24.11.1")
                return model
            }),
            ("instalar-sin-node", {
                let model = WelcomeModel(mode: .firstRun, step: .install)
                model.node = .missing
                return model
            }),
            ("direccion", {
                let model = WelcomeModel(mode: .firstRun, step: .address)
                model.address = "192.168.1.20:3100"
                return model
            }),
            ("direccion-error", {
                let model = WelcomeModel(mode: .firstRun, step: .address)
                model.address = "192.168.1.20:3100"
                model.addressError = PaperclipLocator.ProbeError.unreachable.message
                return model
            }),
            ("cambiar", { WelcomeModel(mode: .change(current: local.url), step: .found(local, health)) }),
        ]
        var controllers: [NSWindowController] = []
        var windows: [Snapshot.Window] = []
        for (name, appearance) in [("claro", NSAppearance.Name.aqua), ("oscuro", .darkAqua)] {
            for item in cases {
                let controller = WelcomeWindowController(model: item.make())
                guard let window = controller.window else { continue }
                window.appearance = NSAppearance(named: appearance)
                Snapshot.hide(window)
                controllers.append(controller)
                windows.append(Snapshot.Window(window: window, file: "\(item.file)-\(name).png"))
            }
            let offline = MainWindowController(
                config: AppConfig(serverURL: Snapshot.placeholderServerURL),
                liquidGlass: false,
                rehearsal: true
            )
            if let window = offline.window {
                window.appearance = NSAppearance(named: appearance)
                Snapshot.hide(window, contentSize: offlineContentSize)
                controllers.append(offline)
                windows.append(Snapshot.Window(window: window, file: "sin-conexion-\(name).png"))
            }
        }
        try? await Task.sleep(for: settleTime)
        await Snapshot.capture(windows, in: directory)
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
            let controller = MainWindowController(config: config, liquidGlass: item.startsWithGlass, rehearsal: true)
            guard let window = controller.window else { continue }
            controller.setUpdateButton(Snapshot.versionButton(nil), visible: true)
            Snapshot.hide(window, contentSize: contentSize)
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
}

/// Una página de Paperclip vista con la app, para capturas de muestra (`macos/snapshot.zsh page <ruta>`). Usa
/// los ajustes de la app (modo y apariencia) y el tamaño pedido (`-PaperclipSnapshotSize 1512x982`). Con
/// anclas (`-PaperclipSnapshotAnchors "|En qué se fue"`, separadas por «|»; vacía es arriba de todo) saca
/// una captura por cada una, con la página desplazada hasta ese texto.
@MainActor
enum PageSnapshot {
    private static let pathKey = "PaperclipSnapshotPath"
    private static let sizeKey = "PaperclipSnapshotSize"
    private static let anchorsKey = "PaperclipSnapshotAnchors"
    private static let defaultSize = NSSize(width: 1512, height: 982)
    /// Lo que tarda la página en armarse y traer sus datos (los plugins leen al abrir).
    private static let loadTime: Duration = .seconds(12)
    private static let scrollTime: Duration = .seconds(2)

    static func run(config: AppConfig, to directory: URL) async {
        let defaults = UserDefaults.standard
        let preferences = Preferences()
        NSApp.appearance = preferences.appearance.nsAppearance
        let path = defaults.string(forKey: pathKey) ?? "/"
        let size = defaults.string(forKey: sizeKey).flatMap(parseSize) ?? defaultSize
        let anchors = (defaults.string(forKey: anchorsKey) ?? "").components(separatedBy: "|")
        let version = await Snapshot.installedVersion()
        var shots: [(controller: MainWindowController, anchor: String)] = []
        var windows: [Snapshot.Window] = []
        for (index, anchor) in anchors.enumerated() {
            let controller = MainWindowController(
                config: config,
                liquidGlass: preferences.liquidGlassPage,
                rehearsal: true
            )
            guard let window = controller.window else { continue }
            Snapshot.hide(window, contentSize: size)
            controller.setUpdateButton(Snapshot.versionButton(version), visible: true)
            controller.load(path: path)
            shots.append((controller, anchor))
            windows.append(Snapshot.Window(window: window, file: "pagina-\(index + 1).png"))
        }
        try? await Task.sleep(for: loadTime)
        for shot in shots where !shot.anchor.isEmpty {
            if await !shot.controller.scrollPage(toText: shot.anchor) {
                NSLog("Paperclip: el ensayo no encontró «%@» en la página", shot.anchor)
            }
        }
        try? await Task.sleep(for: scrollTime)
        await Snapshot.capture(windows, in: directory)
    }

    /// «1512x982» → 1512 × 982 puntos.
    private static func parseSize(_ text: String) -> NSSize? {
        let parts = text.lowercased().split(separator: "x").compactMap { Double($0) }
        guard parts.count == 2, parts[0] > 0, parts[1] > 0 else { return nil }
        return NSSize(width: parts[0], height: parts[1])
    }
}
