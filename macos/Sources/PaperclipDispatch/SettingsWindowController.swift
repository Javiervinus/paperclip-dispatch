import AppKit
import SwiftUI

/// Las pestañas de Ajustes, en el orden del selector.
enum SettingsPane: String, CaseIterable, Identifiable {
    case general, notifications, telegram, paperclip

    var id: Self { self }

    var title: String {
        switch self {
        case .general: String(localized: "General")
        case .notifications: String(localized: "Notifications")
        case .telegram: "Telegram"
        case .paperclip: "Paperclip"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .notifications: "bell.badge"
        case .telegram: "paperplane"
        case .paperclip: "paperclip"
        }
    }

    /// El color con que la pestaña tiñe la parte de arriba de la ventana y su ícono.
    var color: Color {
        switch self {
        case .general: .teal
        case .notifications: .red
        case .telegram: SettingsDesign.telegramBlue
        case .paperclip: .indigo
        }
    }
}

/// Lo que Ajustes le pide a la app.
struct SettingsActions {
    let checkForUpdate: () -> Void
    let installUpdate: () -> Void
    let sendTestNotification: () -> Void
    /// Pide el permiso de avisos (macOS muestra su aviso, solo si nunca se pidió).
    let requestNotifications: () -> Void
    /// Abre la bienvenida para elegir otro Paperclip.
    let changeServer: () -> Void
    let serverURL: URL
    /// Paperclip corre en esta Mac (y se actualiza desde aquí).
    let isLocalServer: Bool
    /// Las versiones de esta app (Ajustes → General).
    let appUpdater: AppUpdater
}

/// La pestaña elegida en Ajustes. Vive en la ventana para que la app pueda abrirla en una pestaña dada
/// (p. ej., «Configurar Telegram» de la sugerencia), también con la ventana ya abierta.
@MainActor
@Observable
final class SettingsSelection {
    private static let paneKey = "settingsPane"

    var pane: SettingsPane {
        didSet { if remembers { UserDefaults.standard.set(pane.rawValue, forKey: Self.paneKey) } }
    }

    @ObservationIgnored private let remembers: Bool

    /// Sin `pane`, la última usada; con ella, esa, sin recordarla (para el ensayo).
    init(pane: SettingsPane? = nil) {
        remembers = pane == nil
        self.pane = pane ?? UserDefaults.standard.string(forKey: Self.paneKey).flatMap(SettingsPane.init) ?? .general
    }
}

/// La ventana Ajustes (Cmd+,): de tamaño fijo, como Ajustes del Sistema, con un selector de Liquid Glass en
/// la barra (la barra es de SwiftUI: `sceneBridgingOptions`) y el contenido pasando por debajo.
@MainActor
final class SettingsWindowController: NSWindowController {
    private let selection: SettingsSelection

    /// `initialPane` abre en esa pestaña sin recordarla (para el ensayo); sin ella, abre en la última usada.
    init(
        preferences: Preferences,
        status: AppStatus,
        telegram: TelegramChannel,
        actions: SettingsActions,
        initialPane: SettingsPane? = nil
    ) {
        let selection = SettingsSelection(pane: initialPane)
        self.selection = selection
        let hosting = NSHostingController(rootView: SettingsRoot(
            preferences: preferences,
            status: status,
            telegram: telegram,
            actions: actions,
            selection: selection
        ))
        hosting.sceneBridgingOptions = [.toolbars]
        hosting.sizingOptions = []
        let window = SnapshotableWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.title = String(localized: "Settings")
        window.titleVisibility = .hidden
        window.toolbarStyle = .unified
        window.setContentSize(SettingsDesign.windowSize)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        super.init(window: window)
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// `pane`: abre en esa pestaña; sin ella, en la que estaba.
    func show(pane: SettingsPane? = nil) {
        if let pane, pane != selection.pane {
            if window?.isVisible == true {
                withAnimation(SettingsDesign.paneAnimation) { selection.pane = pane }
            } else {
                selection.pane = pane
            }
        }
        showWindow(nil)
        NSApp.activate()
    }
}

/// Lo de adentro de la ventana: el selector, el color de la pestaña arriba y la pestaña. Al cambiar de
/// pestaña, el color y el contenido se funden en una sola animación.
private struct SettingsRoot: View {
    let preferences: Preferences
    let status: AppStatus
    let telegram: TelegramChannel
    let actions: SettingsActions
    @Bindable var selection: SettingsSelection

    private var pane: SettingsPane { selection.pane }

    var body: some View {
        ZStack(alignment: .top) {
            ForEach(SettingsPane.allCases) { candidate in
                PaneGlow(color: candidate.color)
                    .opacity(candidate == pane ? 1 : 0)
            }
            SettingsPaneView(
                pane: pane,
                preferences: preferences,
                status: status,
                telegram: telegram,
                actions: actions
            )
            .id(pane)
            .transition(.blurReplace)
        }
        .frame(width: SettingsDesign.windowSize.width, height: SettingsDesign.windowSize.height)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Section", selection: $selection.pane.animation(SettingsDesign.paneAnimation)) {
                    ForEach(SettingsPane.allCases) { pane in
                        Label(pane.title, systemImage: pane.symbol).tag(pane)
                    }
                }
                .pickerStyle(.segmented)
                .labelStyle(.titleOnly)
                .labelsHidden()
            }
        }
    }
}

/// Un resplandor del color de la pestaña detrás de la barra y del encabezado: el vidrio lo refleja.
struct PaneGlow: View {
    @Environment(\.colorScheme) private var colorScheme

    let color: Color

    var body: some View {
        EllipticalGradient(
            colors: [color.opacity(colorScheme == .dark ? 0.42 : 0.3), color.opacity(0)],
            center: .top,
            startRadiusFraction: 0,
            endRadiusFraction: 0.62
        )
        .frame(height: SettingsDesign.glowHeight)
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Ensayo

/// Ensayo visual de Ajustes (`macos/snapshot.zsh settings`): cada pestaña en su ventana, en claro y en
/// oscuro (Telegram también sin bot y sin vincular; Avisos también sin pedir y a medias). Usa el estado
/// real (solo lo lee).
@MainActor
enum SettingsSnapshot {
    /// Lo que tardan las pestañas en terminar de cargar (Telegram busca los CLIs y sus modelos).
    private static let settleTime: Duration = .seconds(5)

    static func run(config: AppConfig, to directory: URL) async {
        let api = PaperclipAPI(serverURL: config.serverURL)
        let preferences = Preferences()
        let status = AppStatus()
        await load(status)
        let actions = SettingsActions(
            checkForUpdate: {},
            installUpdate: {},
            sendTestNotification: {},
            requestNotifications: {},
            changeServer: {},
            serverURL: config.serverURL,
            isLocalServer: PaperclipLocator.isOnThisMac(config.serverURL),
            appUpdater: AppUpdater(previewing: .ready(MainWindowSnapshot.sampleRelease))
        )
        func channel(_ state: TelegramChannel.State?, hasToken: Bool = true) -> TelegramChannel {
            let resolver = DecisionResolver(api: api)
            let explainer = DecisionExplainer(api: api)
            guard let state else { return TelegramChannel(resolver: resolver, explainer: explainer, serverURL: config.serverURL) }
            return TelegramChannel(
                previewing: state,
                hasToken: hasToken,
                resolver: resolver,
                explainer: explainer,
                serverURL: config.serverURL
            )
        }
        let real = channel(nil)
        var pairing = TelegramChannel.State()
        pairing.botUsername = real.state.botUsername
        pairing.pairingCode = TelegramChannel.makePairingCode()
        func statusWith(_ access: NotificationAccess) -> AppStatus {
            let copy = AppStatus()
            copy.paperclipVersion = status.paperclipVersion
            copy.notificationPermission = access.webPermission
            copy.notificationAccess = access
            return copy
        }
        let variants: [(name: String, telegram: TelegramChannel, status: AppStatus, panes: [SettingsPane])] = [
            ("", real, status, SettingsPane.allCases),
            ("telegram-no-bot", channel(TelegramChannel.State(), hasToken: false), status, [.telegram]),
            ("telegram-not-linked", channel(pairing), status, [.telegram]),
            ("notifications-not-requested", real, statusWith(NotificationAccess(permission: .notDetermined, banners: false, badge: false)), [.notifications]),
            ("notifications-partial", real, statusWith(NotificationAccess(permission: .granted, banners: false, badge: true)), [.notifications]),
        ]
        var controllers: [SettingsWindowController] = []
        var windows: [Snapshot.Window] = []
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            for variant in variants {
                for pane in variant.panes {
                    let controller = SettingsWindowController(
                        preferences: preferences,
                        status: variant.status,
                        telegram: variant.telegram,
                        actions: actions,
                        initialPane: pane
                    )
                    guard let window = controller.window else { continue }
                    window.appearance = NSAppearance(named: appearance)
                    Snapshot.hide(window)
                    controllers.append(controller)
                    let prefix = variant.name.isEmpty ? pane.rawValue : variant.name
                    windows.append(Snapshot.Window(window: window, file: "\(prefix)-\(name).png"))
                }
            }
        }
        try? await Task.sleep(for: settleTime)
        await Snapshot.capture(windows, in: directory)
    }

    /// La versión y el permiso de avisos, como los ve la app.
    private static func load(_ status: AppStatus) async {
        let result = await Shell.run(["-c", UpdateController.checkCommand])
        if let check = UpdateController.decode(result) {
            status.paperclipVersion = check.currentVersion
            status.latestVersion = check.updateAvailable ? check.targetVersion : nil
            status.lastCheckedAt = .now
        }
        let access = await NotificationAccess.current()
        status.notificationAccess = access
        status.notificationPermission = access.webPermission
    }
}
