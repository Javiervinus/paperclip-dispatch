import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let notifications = NotificationBridge()
    private let preferences = Preferences()
    private let status = AppStatus()
    private var config: AppConfig?
    private var windowController: MainWindowController?
    private var updates: UpdateController?
    private var plugins: PluginUpdates?
    private var updateNotices: UpdateNotices?
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
                case .about: await AboutSnapshot.run(to: directory)
                case .notifications: await NotificationsSnapshot.run(to: directory)
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
        let pageNotifications = PageNotifications(notifications: notifications, preferences: preferences) {
            MainWindowController.isPaperclip($0, config: config)
        }
        let windowController = MainWindowController(
            config: config,
            liquidGlass: preferences.liquidGlassPage,
            initialURL: AppUpdater.takeRememberedPage(on: config.serverURL),
            pageNotifications: pageNotifications
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
        let api = PaperclipAPI(serverURL: config.serverURL)
        let plugins = PluginUpdates(api: api)
        plugins.onUpdated = { [weak windowController] in windowController?.reload() }
        self.plugins = plugins
        updatesButton = UpdatesButton(
            app: appUpdater,
            status: status,
            plugins: plugins,
            preferences: preferences,
            host: windowController,
            checkPaperclip: { [weak updates] in updates?.checkNow() },
            updatePaperclip: { [weak updates] in updates?.requestUpdate() }
        )
        let updateNotices = UpdateNotices(
            app: appUpdater,
            status: status,
            plugins: plugins,
            preferences: preferences,
            notifications: notifications,
            isInFront: { [weak windowController] in windowController?.isInFront ?? false },
            canPresent: { [weak self, weak windowController] in
                (windowController?.canPresentOverlay ?? false) && self?.nudge?.isVisible != true
            },
            isPanelOpen: { [weak self] panel in
                switch panel {
                case .updates: self?.updatesButton?.isPanelShown ?? false
                case .plugins: self?.updatesButton?.pluginsButton.isPanelShown ?? false
                }
            },
            openPanel: { [weak self] panel in self?.showUpdatesPanel(panel) }
        )
        self.updateNotices = updateNotices
        updatesButton?.onPanelShown = { [weak updateNotices] in updateNotices?.panelOpened(.updates) }
        updatesButton?.pluginsButton.onPanelShown = { [weak updateNotices] in updateNotices?.panelOpened(.plugins) }
        let decisions = DecisionsMonitor(api: api, preferences: preferences, notifications: notifications) {
            [weak windowController] in windowController?.isInFront ?? false
        }
        self.decisions = decisions
        let assignedTasks = AssignedTasksMonitor(
            api: api, resolver: DecisionResolver(api: api), preferences: preferences, notifications: notifications
        ) { [weak windowController] in windowController?.isInFront ?? false }
        decisions.assignedTasks = assignedTasks
        let telegram = TelegramChannel(
            resolver: DecisionResolver(api: api),
            explainer: DecisionExplainer(api: api),
            serverURL: config.serverURL
        )
        self.telegram = telegram
        assignedTasks.telegram = telegram
        // Una sola lectura de «Ver en vivo» por tarea para el aviso de la Mac y el mensaje de Telegram.
        let previews = LivePreviews(api: api)
        decisions.previews = previews
        assignedTasks.previews = previews
        telegram.previews = previews
        let runLimits = RunLimitMonitor(api: api, preferences: preferences, notifications: notifications)
        runLimits.telegram = telegram
        decisions.runLimits = runLimits
        telegram.requestRefresh = { [weak decisions] in decisions?.refresh() }
        decisions.onAttention = { [weak telegram] companyId, items, complete in
            telegram?.update(companyId: companyId, items: items, complete: complete)
        }
        connectGuidance(window: windowController, decisions: decisions, telegram: telegram, pill: updateNotices.pill)

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
        notifications.onPageClick = { [weak windowController] id in
            windowController?.openPageNotification(id: id)
        }
        notifications.onUpdatesClick = { [weak self] panel in self?.showUpdatesPanel(panel) }
        // Lo que se avisó con la app atrás sale también en la ventana al volver.
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: windowController.window, queue: .main
        ) { [weak updateNotices] _ in
            MainActor.assumeIsolated { updateNotices?.cameToFront() }
        }
        notifications.onWake = { [weak decisions] id, wake, href, preview in
            decisions?.wake(wake, notificationId: id, href: href, preview: preview)
        }
        notifications.onPermissionChange = { [weak self] permission in
            self?.status.notificationPermission = permission
            self?.windowController?.refreshPageNotifications()
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
        plugins.start()
        updateNotices.start()
        telegram.start()
        decisions.start()
    }

    /// Las sugerencias (como conectar Telegram) y el recordatorio de avisos: esperan a que se esté usando
    /// Paperclip con la sesión iniciada y nunca salen a la vez.
    private func connectGuidance(
        window: MainWindowController, decisions: DecisionsMonitor, telegram: TelegramChannel, pill: UpdatePill
    ) {
        let tips = TipCenter(host: window) { [weak telegram] tip in
            switch tip {
            case .telegram: telegram.map { !$0.hasToken } ?? false
            }
        }
        // En el mismo lugar que la píldora de versiones nuevas: espera a que se vaya.
        let nudge = NotificationNudge(preferences: preferences, notifications: notifications) { [weak window, weak pill] in
            (window?.canPresentOverlay ?? false) && pill?.isVisible != true
        }
        self.tips = tips
        self.nudge = nudge
        window.setBottomOverlay(BottomPills(nudge: nudge, updates: pill), padding: NotificationNudgeView.shadowRoom)
        tips.onAction = { [weak self] tip in
            switch tip {
            case .telegram: self?.openSettings(at: .telegram)
            }
        }
        tips.onClose = { [weak nudge] in nudge?.sheetClosed() }
        decisions.onSignedIn = { [weak self, weak tips, weak nudge] in
            tips?.signedIn()
            nudge?.signedIn()
            self?.plugins?.signedIn()
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

    /// Segundos que espera la copia nueva a que esta termine de cerrarse.
    private static let relaunchDelay = 1

    private func relaunch() {
        let reopen = Process()
        reopen.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Espera a que esta copia termine de cerrarse antes de abrir la nueva.
        reopen.arguments = ["-c", "sleep \(Self.relaunchDelay); /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        try? reopen.run()
        NSApp.terminate(nil)
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    private func applyPreferences() {
        NSApp.appearance = preferences.appearance.nsAppearance
        decisions?.applyBadge()
        windowController?.setLiquidGlass(preferences.liquidGlassPage)
        windowController?.refreshPageNotifications()
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
                        guard let self else { return }
                        status.requestingNotifications = true
                        Task {
                            _ = await self.notifications.request()
                            self.status.requestingNotifications = false
                        }
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
            body: String(localized: "This is what Decisions notifications look like."),
            href: nil
        )
    }

    @objc func reloadPage(_ sender: Any?) {
        windowController?.reload()
    }

    @objc func showAbout(_ sender: Any?) {
        NSApp.activate()
        AboutPanel.show()
    }

    /// Ventana → Paperclip Dispatch (Cmd+0): la ventana vuelve, como al tocar el ícono del Dock.
    @objc func showMainWindow(_ sender: Any?) {
        _ = applicationShouldHandleReopen(NSApp, hasVisibleWindows: false)
    }

    /// Los enlaces del menú Ayuda (la dirección va en `representedObject`): en el navegador.
    @objc func openLink(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.open(url)
    }

    /// Un clic en el aviso de una versión nueva o «Ver» en su píldora: la ventana al frente y ese panel.
    private func showUpdatesPanel(_ panel: UpdateNotices.Panel) {
        guard let windowController else { return }
        windowController.showWindow(nil)
        NSApp.activate()
        switch panel {
        case .updates: updatesButton?.showPanel()
        case .plugins: updatesButton?.pluginsButton.showPanel()
        }
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
