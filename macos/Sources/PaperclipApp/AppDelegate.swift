import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let notifications = NotificationBridge()
    private let preferences = Preferences()
    private let status = AppStatus()
    private var config: AppConfig?
    private var windowController: MainWindowController?
    private var updates: UpdateController?
    private var decisions: DecisionsMonitor?
    private var telegram: TelegramChannel?
    private var settingsWindow: SettingsWindowController?
    private var appearanceObservation: NSKeyValueObservation?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // El ensayo de Ajustes corre como una segunda copia: sin ícono en el Dock ni foco.
        if SettingsSnapshot.directory != nil { NSApp.setActivationPolicy(.accessory) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let config = AppConfig.load() else {
            let alert = NSAlert()
            alert.messageText = "Falta la dirección de Paperclip"
            alert.informativeText = "Vuelve a armar la app con macos/build.sh: la dirección sale de tailscale serve."
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        self.config = config
        if let directory = SettingsSnapshot.directory {
            // No abre Paperclip ni atiende el bot: solo dibuja Ajustes y se cierra.
            Task {
                await SettingsSnapshot.run(config: config, to: directory)
                NSApp.terminate(nil)
            }
            return
        }
        NSApp.mainMenu = MainMenu.build(appName: AppConfig.appName)
        // Antes de crear la ventana, para que la página cargue ya con el tema elegido.
        NSApp.appearance = preferences.appearance.nsAppearance

        let windowController = MainWindowController(config: config, liquidGlass: preferences.liquidGlassPage)
        self.windowController = windowController
        updates = UpdateController(config: config, host: windowController, notifications: notifications, status: status)
        let api = PaperclipAPI(serverURL: config.serverURL)
        let decisions = DecisionsMonitor(api: api, preferences: preferences, notifications: notifications) {
            [weak windowController] in windowController?.isInFront ?? false
        }
        self.decisions = decisions
        let telegram = TelegramChannel(
            resolver: DecisionResolver(api: api),
            explainer: DecisionExplainer(api: api),
            serverURL: config.serverURL
        )
        self.telegram = telegram
        telegram.requestRefresh = { [weak decisions] in decisions?.refresh() }
        decisions.onAttention = { [weak telegram] companyId, items, complete in
            telegram?.update(companyId: companyId, items: items, complete: complete)
        }

        preferences.onChange = { [weak self] in self?.applyPreferences() }
        windowController.onThemeChosen = { [weak self] dark in
            self?.preferences.appearance = dark ? .dark : .light
        }
        // La apariencia efectiva cambia con Ajustes y, en «Sistema», cuando la Mac pasa a claro u oscuro.
        // KVO de NSApp avisa en el hilo principal.
        appearanceObservation = NSApp.observe(\.effectiveAppearance, options: [.new]) {
            [weak windowController] app, _ in
            MainActor.assumeIsolated {
                let dark = app.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                windowController?.setPageTheme(dark: dark)
            }
        }
        notifications.onClick = { [weak windowController] href in
            windowController?.openNotification(href: href)
        }
        notifications.onPermissionChange = { [weak self] permission in
            self?.status.notificationPermission = permission
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.decisions?.refresh() }
        }

        windowController.showWindow(nil)
        notifications.start()
        updates?.start()
        telegram.start()
        decisions.start()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // El permiso de avisos se puede cambiar en Ajustes del Sistema con la app abierta.
        notifications.refresh()
        decisions?.refresh()
    }

    // Clic en el ícono del Dock con la ventana cerrada: se vuelve a mostrar.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        windowController?.showWindow(nil)
        return true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    private func applyPreferences() {
        NSApp.appearance = preferences.appearance.nsAppearance
        decisions?.applyBadge()
        windowController?.setLiquidGlass(preferences.liquidGlassPage)
    }

    @objc func showSettings(_ sender: Any?) {
        guard let config, let telegram else { return }
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController(
                preferences: preferences,
                status: status,
                telegram: telegram,
                actions: SettingsActions(
                    checkForUpdate: { [weak self] in self?.updates?.checkNow() },
                    installUpdate: { [weak self] in self?.updates?.requestUpdate() },
                    sendTestNotification: { [weak self] in self?.sendTestNotification() },
                    serverURL: config.serverURL
                )
            )
        }
        settingsWindow?.show()
    }

    private func sendTestNotification() {
        notifications.show(
            id: "paperclip-test",
            tag: "paperclip-test",
            title: "Paperclip",
            body: "Así llegan los avisos de Decisions.",
            href: nil
        )
    }

    @objc func reloadPage(_ sender: Any?) {
        windowController?.reload()
    }

    @objc func checkForPaperclipUpdate(_ sender: Any?) {
        updates?.check(userInitiated: true)
    }
}
