import AppKit
import SwiftUI

/// Una ventana que los ensayos pueden dejar casi entera fuera de la pantalla y más alta que ella. Por
/// defecto macOS la acomoda: deja asomar unos 40 puntos y la achica al alto de la pantalla.
final class SnapshotableWindow: NSWindow {
    var keepsFrame = false

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        keepsFrame ? frameRect : super.constrainFrameRect(frameRect, to: screen)
    }
}

/// Ensayos visuales, para revisar el diseño sin tapar nada en pantalla. Los corre `macos/snapshot.zsh`: abre
/// una segunda copia de la app con `-PaperclipSnapshot <settings|window|page|welcome|about|notifications>` y
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
        case settings, window, page, welcome, about, notifications
    }

    struct Window {
        let window: NSWindow
        let file: String
    }

    private static let kindKey = "PaperclipSnapshot"
    private static let directoryKey = "PaperclipSnapshotDirectory"
    private static let activeKey = "PaperclipSnapshotActive"
    /// Segundos que espera a que el script capture; el script espera lo mismo a que la app anote sus ventanas.
    private static let captureTimeout = 90
    /// Lo que tarda una ventana recién puesta al frente en dibujarse como activa.
    private static let activeSettleTime: Duration = .seconds(1.5)

    /// Para ensayar sin dirección elegida: no responde nada ahí. No sirve un puerto de los que WebKit bloquea
    /// (como el 9): con esos no avisa que la carga falló.
    static let placeholderServerURL = URL(string: "http://127.0.0.1:65535")!

    /// La versión de Paperclip que muestran los ensayos cuando no hay una instalada.
    static let sampleVersion = "2026.1023.0"

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

    /// El botón de actualizaciones de verdad, al día con la versión de Paperclip dada (para los ensayos).
    static func upToDateButton(paperclip version: String?, host: MainWindowController) -> UpdatesButton {
        let status = AppStatus()
        status.paperclipVersion = version ?? sampleVersion
        status.lastCheckedAt = .now
        return UpdatesButton(
            app: AppUpdater(previewing: .idle),
            status: status,
            plugins: PluginUpdates(previewing: []),
            preferences: Preferences(),
            host: host,
            checkPaperclip: {},
            updatePaperclip: {}
        )
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
/// muestra (no busca, no enciende ni pide nada), la sugerencia de Telegram y la ventana de Paperclip cuando
/// no responde.
@MainActor
enum WelcomeSnapshot {
    private static let offlineContentSize = NSSize(width: 960, height: 620)
    /// Lo que tarda en fallar la carga de la dirección muerta y en mostrarse el aviso.
    private static let settleTime: Duration = .seconds(4)

    static func run(to directory: URL) async {
        let version = await Snapshot.installedVersion()?.currentVersion ?? Snapshot.sampleVersion
        let local = LocalPaperclip(
            instanceId: "default",
            url: URL(string: "http://127.0.0.1:\(PaperclipLocator.defaultPort)")!,
            port: PaperclipLocator.defaultPort,
            hasService: true
        )
        let health = PaperclipHealth(status: "ok", deploymentMode: "local_trusted", version: version)
        func connect(_ step: WelcomeModel.Step) -> WelcomeModel {
            WelcomeModel(mode: .firstRun, step: step, phase: .connect)
        }
        func notifications(_ access: NotificationAccess) -> WelcomeModel {
            WelcomeModel(mode: .firstRun, step: .found(local, health), phase: .notifications, notificationAccess: access)
        }
        let cases: [(file: String, make: () -> WelcomeModel)] = [
            ("start", { WelcomeModel(mode: .firstRun, step: .found(local, health)) }),
            ("found", { connect(.found(local, health)) }),
            ("stopped", { connect(.stopped(local)) }),
            ("not-found", { connect(.notFound) }),
            ("install", {
                let model = connect(.install)
                model.node = .ready("v24.11.1")
                return model
            }),
            ("install-without-node", {
                let model = connect(.install)
                model.node = .missing
                return model
            }),
            ("address", {
                let model = connect(.address)
                model.address = "192.168.1.20:3100"
                return model
            }),
            ("address-error", {
                let model = connect(.address)
                model.address = "192.168.1.20:3100"
                model.addressError = PaperclipLocator.ProbeError.unreachable.message
                return model
            }),
            ("notifications", { notifications(NotificationAccess(permission: .notDetermined, banners: false, badge: false)) }),
            ("notifications-allowed", { notifications(NotificationAccess(permission: .granted, banners: true, badge: true)) }),
            ("notifications-partial", { notifications(NotificationAccess(permission: .granted, banners: false, badge: true)) }),
            ("notifications-off", { notifications(NotificationAccess(permission: .denied, banners: false, badge: false)) }),
            ("change", { WelcomeModel(mode: .change(current: local.url), step: .found(local, health)) }),
        ]
        var controllers: [NSWindowController] = []
        var tipWindows: [NSWindow] = []
        var windows: [Snapshot.Window] = []
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            for item in cases {
                let controller = WelcomeWindowController(model: item.make())
                guard let window = controller.window else { continue }
                window.appearance = NSAppearance(named: appearance)
                Snapshot.hide(window)
                controllers.append(controller)
                windows.append(Snapshot.Window(window: window, file: "\(item.file)-\(name).png"))
            }
            for tip in Tip.allCases {
                let sheet = tipWindow(tip)
                sheet.appearance = NSAppearance(named: appearance)
                Snapshot.hide(sheet)
                tipWindows.append(sheet)
                windows.append(Snapshot.Window(window: sheet, file: "tip-\(tip.rawValue)-\(name).png"))
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
                windows.append(Snapshot.Window(window: window, file: "offline-\(name).png"))
            }
        }
        try? await Task.sleep(for: settleTime)
        await Snapshot.capture(windows, in: directory)
        withExtendedLifetime(tipWindows) {}
    }

    /// La hoja de una sugerencia en una ventana suelta, sin barra, como se ve sobre la de Paperclip.
    private static func tipWindow(_ tip: Tip) -> NSWindow {
        let hosting = NSHostingController(rootView: TipSheetView(tip: tip, onAction: {}, onDismiss: {}))
        hosting.sizingOptions = []
        let window = SnapshotableWindow(contentViewController: hosting)
        window.styleMask = [.titled, .fullSizeContentView]
        window.setContentSize(hosting.sizeThatFits(in: MainWindowController.unboundedSize))
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        return window
    }
}

/// Ensayo de la ventana de Paperclip (`macos/snapshot.zsh window`): el modo normal y el de Liquid Glass, al
/// abrir y al cambiar de uno a otro con la página ya cargada, que es lo que hace el ajuste. Lleva un botón
/// de versión de muestra y, en dos, el recordatorio de avisos.
@MainActor
enum MainWindowSnapshot {
    private static let contentSize = NSSize(width: 1280, height: 800)
    private static let loadTime: Duration = .seconds(8)

    /// Lo que muestra el botón de actualizaciones en cada captura.
    private enum Updates {
        case upToDate, dispatch, both, plugin, all, whatsNew
    }

    /// Lo que va abajo en la ventana.
    private enum Overlay {
        case nudge(NotificationNudge.Problem)
        /// La píldora de versiones nuevas, con esas.
        case updates([UpdatePill.Item])
    }

    /// Plugins de muestra: dos de npm con versión nueva, dos al día y uno que sale de una carpeta.
    static let samplePlugins = [
        PluginUpdates.Plugin(
            id: "sample-office",
            name: "Oficina global",
            version: "0.12.1",
            source: .npm("paperclip-plugin-oficina-global"),
            latest: "0.13.0"
        ),
        PluginUpdates.Plugin(id: "sample-usage", name: "Consumo de agentes", version: "0.6.0", source: .folder),
        PluginUpdates.Plugin(
            id: "sample-telegram",
            name: "Telegram",
            version: "0.8.0",
            source: .npm("paperclip-plugin-telegram"),
            latest: "0.8.1"
        ),
        PluginUpdates.Plugin(id: "sample-slack", name: "Slack", version: "2.1.0", source: .npm("paperclip-plugin-slack")),
        PluginUpdates.Plugin(id: "sample-github", name: "GitHub", version: "0.18.0", source: .npm("paperclip-github-plugin")),
    ]

    /// Los mismos, todos al día.
    static var samplePluginsUpToDate: [PluginUpdates.Plugin] {
        samplePlugins.map { plugin in
            var plugin = plugin
            if let latest = plugin.latest { plugin.version = latest }
            plugin.latest = nil
            return plugin
        }
    }

    /// Novedades de muestra para el ensayo del botón y el panel.
    static let sampleRelease = AppUpdater.Release(
        version: "0.2.0",
        notes: String(localized: """
            - **Phone notifications with ntfy.** Pick a topic in Settings and decisions reach any phone.
            - **The window remembers its page.** After an update, it opens where you left off.
            """),
        notesURL: nil
    )

    static func run(config: AppConfig, to directory: URL) async {
        let paperclipItem = UpdateNotices.paperclipItem("2026.1101.0")
        let pluginsItem = UpdateNotices.pluginsItem(samplePlugins.filter { $0.latest != nil })
        let cases: [(file: String, startsWithGlass: Bool, switches: Bool, updates: Updates, overlay: Overlay?)] = [
            ("normal", false, false, .upToDate, nil),
            ("glass", true, false, .upToDate, nil),
            ("normal-to-glass", false, true, .upToDate, nil),
            ("glass-to-normal", true, true, .upToDate, nil),
            ("dispatch-normal", false, false, .dispatch, nil),
            ("dispatch-glass", true, false, .dispatch, nil),
            ("both-glass", true, false, .both, nil),
            ("plugin-glass", true, false, .plugin, nil),
            ("all-glass", true, false, .all, nil),
            ("whats-new-glass", true, false, .whatsNew, nil),
            ("notifications-off-normal", false, false, .upToDate, .nudge(.off)),
            ("notifications-partial-glass", true, false, .upToDate, .nudge(.noBanners)),
            ("update-pill-paperclip-glass", true, false, .both, .updates([paperclipItem])),
            ("update-pill-several-glass", true, false, .all, .updates([
                UpdateNotices.dispatchItem(sampleRelease.version, ready: true), paperclipItem, pluginsItem,
            ])),
            ("update-pill-plugins-normal", false, false, .plugin, .updates([
                UpdateNotices.pluginsItem([samplePlugins[0]]),
            ])),
        ]
        let preferences = Preferences()
        let notifications = NotificationBridge()
        let paperclip = await Snapshot.installedVersion()?.currentVersion
        var controllers: [(controller: MainWindowController, switches: Bool, glass: Bool)] = []
        var buttons: [UpdatesButton] = []
        var windows: [Snapshot.Window] = []
        for item in cases {
            let controller = MainWindowController(config: config, liquidGlass: item.startsWithGlass, rehearsal: true)
            guard let window = controller.window else { continue }
            let status = AppStatus()
            status.paperclipVersion = paperclip ?? Snapshot.sampleVersion
            status.lastCheckedAt = .now
            let app: AppUpdater
            var plugins = [samplePlugins[1]]
            switch item.updates {
            case .upToDate: app = AppUpdater(previewing: .idle)
            case .dispatch: app = AppUpdater(previewing: .ready(sampleRelease))
            case .both:
                app = AppUpdater(previewing: .ready(sampleRelease))
                status.latestVersion = "2026.1101.0"
            case .plugin:
                app = AppUpdater(previewing: .idle)
                plugins = [samplePlugins[0], samplePlugins[1]]
            case .all:
                app = AppUpdater(previewing: .ready(sampleRelease))
                status.latestVersion = "2026.1101.0"
                plugins = samplePlugins
            case .whatsNew: app = AppUpdater(previewing: .idle, whatsNew: sampleRelease)
            }
            buttons.append(UpdatesButton(
                app: app, status: status, plugins: PluginUpdates(previewing: plugins), preferences: preferences,
                host: controller, checkPaperclip: {}, updatePaperclip: {}
            ))
            switch item.overlay {
            case .nudge(let problem):
                let nudge = NotificationNudge(previewing: problem, preferences: preferences, notifications: notifications)
                controller.setBottomOverlay(NotificationNudgeView(model: nudge), padding: NotificationNudgeView.shadowRoom)
            case .updates(let items):
                controller.setBottomOverlay(UpdatePillView(model: UpdatePill(previewing: items)), padding: NotificationNudgeView.shadowRoom)
            case nil:
                break
            }
            Snapshot.hide(window, contentSize: contentSize)
            controllers.append((controller, item.switches, item.startsWithGlass))
            windows.append(Snapshot.Window(window: window, file: "\(item.file).png"))
        }
        windows += panelWindows(paperclip: paperclip ?? Snapshot.sampleVersion)
        try? await Task.sleep(for: loadTime)
        for entry in controllers where entry.switches {
            entry.controller.setLiquidGlass(!entry.glass)
        }
        try? await Task.sleep(for: loadTime)
        await Snapshot.capture(windows, in: directory)
        withExtendedLifetime(buttons) {}
    }

    /// El panel de actualizaciones solo, en una ventana: con todo por actualizar, con la lista de plugins
    /// abierta, con un plugin actualizándose y con los plugins al día.
    private static func panelWindows(paperclip: String) -> [Snapshot.Window] {
        let cases: [(file: String, plugins: [PluginUpdates.Plugin], updating: String?, showsAll: Bool, notifies: Bool)] = [
            ("updates-panel-all", samplePlugins, nil, false, true),
            ("updates-panel-plugins-list", samplePlugins, nil, true, true),
            ("updates-panel-plugin-updating", samplePlugins, samplePlugins[0].id, false, true),
            ("updates-panel-plugins-up-to-date", samplePluginsUpToDate, nil, false, false),
        ]
        return cases.map { item in
            let status = AppStatus()
            status.paperclipVersion = paperclip
            status.latestVersion = "2026.1101.0"
            status.lastCheckedAt = .now
            let panel = UpdatesPanel(
                app: AppUpdater(previewing: .ready(sampleRelease)),
                status: status,
                plugins: PluginUpdates(previewing: item.plugins, updatingID: item.updating),
                actions: UpdatesPanelActions(checkAll: {}, updatePaperclip: {}),
                notifiesOfNewVersions: .constant(item.notifies),
                showsAllPlugins: item.showsAll
            )
            let hosting = NSHostingController(rootView: panel)
            hosting.sizingOptions = []
            let window = SnapshotableWindow(contentViewController: hosting)
            window.styleMask = [.titled, .fullSizeContentView]
            window.setContentSize(hosting.sizeThatFits(in: MainWindowController.unboundedSize))
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            Snapshot.hide(window)
            return Snapshot.Window(window: window, file: "\(item.file).png")
        }
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
        var buttons: [UpdatesButton] = []
        var windows: [Snapshot.Window] = []
        for (index, anchor) in anchors.enumerated() {
            let controller = MainWindowController(
                config: config,
                liquidGlass: preferences.liquidGlassPage,
                rehearsal: true
            )
            guard let window = controller.window else { continue }
            Snapshot.hide(window, contentSize: size)
            buttons.append(Snapshot.upToDateButton(paperclip: version?.currentVersion, host: controller))
            controller.load(path: path)
            shots.append((controller, anchor))
            windows.append(Snapshot.Window(window: window, file: "page-\(index + 1).png"))
        }
        try? await Task.sleep(for: loadTime)
        for shot in shots where !shot.anchor.isEmpty {
            if await !shot.controller.scrollPage(toText: shot.anchor) {
                NSLog("Paperclip Dispatch: the snapshot did not find “%@” on the page", shot.anchor)
            }
        }
        try? await Task.sleep(for: scrollTime)
        await Snapshot.capture(windows, in: directory)
        withExtendedLifetime(buttons) {}
    }

    /// «1512x982» → 1512 × 982 puntos.
    private static func parseSize(_ text: String) -> NSSize? {
        let parts = text.lowercased().split(separator: "x").compactMap { Double($0) }
        guard parts.count == 2, parts[0] > 0, parts[1] > 0 else { return nil }
        return NSSize(width: parts[0], height: parts[1])
    }
}
