import AppKit
import SwiftUI
import UserNotifications

/// Las pestañas de Ajustes, en el orden del selector.
enum SettingsPane: String, CaseIterable, Identifiable {
    case general, notifications, telegram, paperclip

    var id: Self { self }

    var title: String {
        switch self {
        case .general: "General"
        case .notifications: "Avisos"
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
    let serverURL: URL
}

/// La ventana Ajustes (Cmd+,): de tamaño fijo, como Ajustes del Sistema, con un selector de Liquid Glass en
/// la barra (la barra es de SwiftUI: `sceneBridgingOptions`) y el contenido pasando por debajo.
@MainActor
final class SettingsWindowController: NSWindowController {
    /// `initialPane` abre en esa pestaña sin recordarla (para el ensayo); sin ella, abre en la última usada.
    init(
        preferences: Preferences,
        status: AppStatus,
        telegram: TelegramChannel,
        actions: SettingsActions,
        initialPane: SettingsPane? = nil
    ) {
        let hosting = NSHostingController(rootView: SettingsRoot(
            preferences: preferences,
            status: status,
            telegram: telegram,
            actions: actions,
            initialPane: initialPane
        ))
        hosting.sceneBridgingOptions = [.toolbars]
        hosting.sizingOptions = []
        let window = SnapshotableWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.title = "Ajustes"
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
        fatalError("init(coder:) no se usa")
    }

    func show() {
        showWindow(nil)
        NSApp.activate()
    }
}

/// Lo de adentro de la ventana: el selector, el color de la pestaña arriba y la pestaña. Al cambiar de
/// pestaña, el color y el contenido se funden en una sola animación.
private struct SettingsRoot: View {
    private static let paneKey = "settingsPane"

    let preferences: Preferences
    let status: AppStatus
    let telegram: TelegramChannel
    let actions: SettingsActions

    private let remembers: Bool
    @State private var pane: SettingsPane

    init(
        preferences: Preferences,
        status: AppStatus,
        telegram: TelegramChannel,
        actions: SettingsActions,
        initialPane: SettingsPane?
    ) {
        self.preferences = preferences
        self.status = status
        self.telegram = telegram
        self.actions = actions
        remembers = initialPane == nil
        let saved = UserDefaults.standard.string(forKey: Self.paneKey).flatMap(SettingsPane.init)
        _pane = State(initialValue: initialPane ?? saved ?? .general)
    }

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
                Picker("Sección", selection: $pane.animation(SettingsDesign.paneAnimation)) {
                    ForEach(SettingsPane.allCases) { pane in
                        Label(pane.title, systemImage: pane.symbol).tag(pane)
                    }
                }
                .pickerStyle(.segmented)
                .labelStyle(.titleOnly)
                .labelsHidden()
            }
        }
        .onChange(of: pane) {
            if remembers { UserDefaults.standard.set(pane.rawValue, forKey: Self.paneKey) }
        }
    }
}

/// Un resplandor del color de la pestaña detrás de la barra y del encabezado: el vidrio lo refleja.
private struct PaneGlow: View {
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
/// oscuro (Telegram también sin bot y sin vincular). Usa el estado real (solo lo lee).
@MainActor
enum SettingsSnapshot {
    /// Lo que tardan las pestañas en terminar de cargar (Telegram busca los CLIs y sus modelos).
    private static let settleTime: Duration = .seconds(5)

    static func run(config: AppConfig, to directory: URL) async {
        let api = PaperclipAPI(serverURL: config.serverURL)
        let preferences = Preferences()
        let status = AppStatus()
        await load(status)
        let actions = SettingsActions(checkForUpdate: {}, installUpdate: {}, sendTestNotification: {}, serverURL: config.serverURL)
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
        let variants: [(name: String, telegram: TelegramChannel, panes: [SettingsPane])] = [
            ("", real, SettingsPane.allCases),
            ("telegram-sin-bot", channel(TelegramChannel.State(), hasToken: false), [.telegram]),
            ("telegram-sin-vincular", channel(pairing), [.telegram]),
        ]
        var controllers: [SettingsWindowController] = []
        var windows: [Snapshot.Window] = []
        for (name, appearance) in [("claro", NSAppearance.Name.aqua), ("oscuro", .darkAqua)] {
            for variant in variants {
                for pane in variant.panes {
                    let controller = SettingsWindowController(
                        preferences: preferences,
                        status: status,
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
        if result.status == 0, let check = UpdateController.decode(result.output) {
            status.paperclipVersion = check.currentVersion
            status.latestVersion = check.updateAvailable ? check.targetVersion : nil
            status.lastCheckedAt = .now
        }
        status.notificationPermission = switch await UNUserNotificationCenter.current().notificationSettings()
            .authorizationStatus {
        case .authorized, .provisional, .ephemeral: "granted"
        case .denied: "denied"
        default: "default"
        }
    }
}
