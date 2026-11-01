import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let notifications = NotificationBridge()
    private let preferences = Preferences()
    private let status = AppStatus()
    private var config: AppConfig?
    private var windowController: MainWindowController?
    private var updates: UpdateController?
    /// Las versiones de esta app. Existe desde el arranque: busca aunque todavía no haya Paperclip elegido.
    private let appUpdater = AppUpdater()
    private var updatesButton: UpdatesButton?
    private var decisions: DecisionsMonitor?
    private var telegram: TelegramChannel?
    private var tips: TipCenter?
    private var nudge: NotificationNudge?
    private var settingsWindow: SettingsWindowController?
    private var welcome: WelcomeWindowController?
    private var appearanceObservation: NSKeyValueObservation?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Los ensayos corren como una segunda copia: sin ícono en el Dock ni foco. Salvo los de ventanas
        // activas, que tienen que poder pasar al frente.
        if Snapshot.requested != nil, !Snapshot.active { NSApp.setActivationPolicy(.accessory) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let (kind, directory) = Snapshot.requested {
            // No atiende el bot ni avisa: solo dibuja lo pedido y se cierra. Sin dirección elegida, la ventana
            // de Paperclip sale sin conexión, pero Ajustes y la bienvenida se ven igual.
            let config = AppConfig.load() ?? AppConfig(serverURL: Snapshot.placeholderServerURL)
            Task {
                switch kind {
                case .settings: await SettingsSnapshot.run(config: config, to: directory)
                case .window: await MainWindowSnapshot.run(config: config, to: directory)
                case .page: await PageSnapshot.run(config: config, to: directory)
                case .welcome: await WelcomeSnapshot.run(to: directory)
                }
                NSApp.terminate(nil)
            }
            return
        }
        NSApp.mainMenu = MainMenu.build(appName: AppConfig.appName)
        LoginItem.followMove()
        appUpdater.willRelaunch = { [weak self] in AppUpdater.rememberPage(self?.windowController?.pageURL) }
        appUpdater.onShowRequested = { [weak self] in
            self?.windowController?.showWindow(nil)
            self?.updatesButton?.showPanel()
        }
        appUpdater.start()
        // Antes de crear la ventana, para que la página cargue ya con el tema elegido.
        NSApp.appearance = preferences.appearance.nsAppearance
        if let config = AppConfig.load() {
            connect(config)
        } else {
            showWelcome(.firstRun)
        }
    }

    /// Arma todo alrededor del Paperclip elegido: la ventana, las versiones, los avisos y el bot.
    private func connect(_ config: AppConfig) {
        self.config = config
        let windowController = MainWindowController(
            config: config,
            liquidGlass: preferences.liquidGlassPage,
            initialURL: AppUpdater.takeRememberedPage(on: config.serverURL)
        )
        self.windowController = windowController
        let updates = UpdateController(
            config: config,
            isLocal: PaperclipLocator.isOnThisMac(config.serverURL),
            host: windowController,
            notifications: notifications,
            status: status
        )
        self.updates = updates
        updatesButton = UpdatesButton(
            app: appUpdater,
            status: status,
            host: windowController,
            checkPaperclip: { [weak updates] in updates?.checkNow() },
            updatePaperclip: { [weak updates] in updates?.requestUpdate() }
        )
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
        connectGuidance(window: windowController, decisions: decisions, telegram: telegram)

        preferences.onChange = { [weak self] in self?.applyPreferences() }
        windowController.onThemeChosen = { [weak self] dark in
            self?.preferences.appearance = dark ? .dark : .light
        }
        windowController.onChangeServer = { [weak self] in self?.changeServer() }
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
        notifications.onAccessChange = { [weak self] access in
            self?.status.notificationAccess = access
            self?.nudge?.update(access)
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.decisions?.refresh() }
        }

        windowController.showWindow(nil)
        notifications.start()
        updates.start()
        telegram.start()
        decisions.start()
    }

    /// Las sugerencias (como conectar Telegram) y el recordatorio de avisos: esperan a que se esté usando
    /// Paperclip con la sesión iniciada y nunca salen a la vez.
    private func connectGuidance(window: MainWindowController, decisions: DecisionsMonitor, telegram: TelegramChannel) {
        let tips = TipCenter(host: window) { [weak telegram] tip in
            switch tip {
            case .telegram: telegram.map { !$0.hasToken } ?? false
            }
        }
        let nudge = NotificationNudge(preferences: preferences, notifications: notifications) { [weak window] in
            window?.canPresentOverlay ?? false
        }
        self.tips = tips
        self.nudge = nudge
        window.setBottomOverlay(NotificationNudgeView(model: nudge), padding: NotificationNudgeView.shadowRoom)
        tips.onAction = { [weak self] tip in
            switch tip {
            case .telegram: self?.openSettings(at: .telegram)
            }
        }
        tips.onClose = { [weak nudge] in nudge?.sheetClosed() }
        decisions.onSignedIn = { [weak tips, weak nudge] in
            tips?.signedIn()
            nudge?.signedIn()
        }
        // Al iniciar sesión la página cambia de dirección: se revisa ya, sin esperar la vuelta del minuto.
        window.onPageChange = { [weak decisions] in
            if decisions?.signedOut == true { decisions?.refresh() }
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // El permiso de avisos se puede cambiar en Ajustes del Sistema con la app abierta.
        notifications.refresh()
        decisions?.refresh()
    }

    // Clic en el ícono del Dock con la ventana cerrada: se vuelve a mostrar.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if let windowController {
            windowController.showWindow(nil)
        } else {
            showWelcome(.firstRun)
        }
        return true
    }

    // MARK: - Bienvenida

    private func showWelcome(_ mode: WelcomeModel.Mode) {
        if let welcome {
            welcome.show()
            return
        }
        let model = WelcomeModel(mode: mode)
        let controller = WelcomeWindowController(model: model)
        model.onConnect = { [weak self] url in self?.choose(url) }
        model.onCancel = { [weak self] in
            self?.welcome?.dismiss()
            self?.welcome = nil
        }
        controller.onClose = { [weak self] in
            self?.welcome = nil
            // La primera vez, cerrar la bienvenida es no usar la app todavía.
            if self?.config == nil { NSApp.terminate(nil) }
        }
        welcome = controller
        controller.show()
        model.start()
    }

    private func changeServer() {
        guard let config else { return }
        showWelcome(.change(current: config.serverURL))
    }

    /// La primera vez se conecta ahí mismo. Al cambiar de Paperclip, la app se vuelve a abrir: la ventana,
    /// los avisos y el bot quedan atados a la dirección con que arrancaron.
    private func choose(_ url: URL) {
        welcome?.dismiss()
        welcome = nil
        AppConfig.save(serverURL: url)
        guard let current = config else {
            connect(AppConfig(serverURL: url))
            return
        }
        if current.serverURL != url { relaunch() }
    }

    private func relaunch() {
        let reopen = Process()
        reopen.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Espera a que esta copia termine de cerrarse antes de abrir la nueva.
        reopen.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        try? reopen.run()
        NSApp.terminate(nil)
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    private func applyPreferences() {
        NSApp.appearance = preferences.appearance.nsAppearance
        decisions?.applyBadge()
        windowController?.setLiquidGlass(preferences.liquidGlassPage)
        nudge?.preferencesChanged()
    }

    @objc func showSettings(_ sender: Any?) {
        openSettings(at: nil)
    }

    /// `pane`: abre Ajustes en esa pestaña (p. ej., Telegram desde su sugerencia); sin ella, en la última.
    private func openSettings(at pane: SettingsPane?) {
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
                    requestNotifications: { [weak self] in
                        Task { _ = await self?.notifications.request() }
                    },
                    changeServer: { [weak self] in self?.changeServer() },
                    serverURL: config.serverURL,
                    isLocalServer: PaperclipLocator.isOnThisMac(config.serverURL),
                    appUpdater: appUpdater
                )
            )
        }
        settingsWindow?.show(pane: pane)
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

    /// «Buscar actualizaciones…» del menú: la ventana al frente y el panel con las dos, revisando.
    @objc func checkForUpdates(_ sender: Any?) {
        guard let windowController else {
            appUpdater.checkNow()
            return
        }
        windowController.showWindow(nil)
        NSApp.activate()
        updatesButton?.showPanelAndCheck()
    }
}
