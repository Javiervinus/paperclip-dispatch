import AppKit
import WebKit

/// Contenedor con el origen arriba a la izquierda, como la página: los rectángulos que manda glass.js
/// se usan tal cual.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// La ventana de Paperclip, en capas:
/// 1. Un fondo del mismo color que el de Paperclip: alrededor del panel no se nota otro gris.
/// 2. El panel de la barra lateral: material translúcido de macOS con Liquid Glass (NSGlassEffectView)
///    encima, ubicado donde glass.js dice que está la barra lateral de Paperclip. El vidrio va recortado
///    al panel: su sombra hacia afuera, invisible en oscuro, en claro agrisaba el margen.
/// 3. La página, transparente donde glass.css le quita el fondo.
/// Una barra de herramientas vacía hace lo que hacen las apps de macOS 26: esquinas de ventana más
/// redondas y los botones de la ventana adentro del panel, donde macOS los pone solo.
@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate,
    WKScriptMessageHandler
{
    private static let frameAutosaveName = "PaperclipMainWindow"
    private static let messageHandlerName = "paperclipApp"
    private static let defaultContentSize = NSSize(width: 1440, height: 900)
    private static let minimumContentSize = NSSize(width: 520, height: 420)
    private static let zoomRange: ClosedRange<CGFloat> = 0.5...2
    private static let zoomStep: CGFloat = 0.1
    /// Separación del botón de la versión con el borde derecho.
    private static let accessoryMargin: CGFloat = 16

    private let config: AppConfig
    private static let toolbarIdentifier = "PaperclipMainToolbar"

    private let base = NSView()
    private let sidebarBackdrop = NSVisualEffectView()
    private let sidebarGlass = NSGlassEffectView()
    /// Recorta el vidrio a su borde.
    private let sidebarClip = NSView()
    private var sidebarRadius: CGFloat = -1
    private let downloads = DownloadHandler()
    private var webView: WKWebView!
    private var pointerOverDragArea = false
    private var mouseDownMonitor: Any?

    private var updateButton: NSButton?
    private var updateButtonCenterY: NSLayoutConstraint?
    private var updateButtonWanted = false
    /// Alto de las barras de arriba de Paperclip (--sz-60px), en puntos; lo informa glass.js.
    private var topBarHeight: CGFloat = 0
    /// En la vista angosta de Paperclip (móvil) la barra de arriba es otra y no hay lugar para el botón.
    private var pageIsDesktop = true

    /// Se eligió el tema en el menú de Paperclip (true = oscuro): la app lo adopta como ajuste.
    var onThemeChosen: ((_ dark: Bool) -> Void)?

    init(config: AppConfig) {
        self.config = config
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.defaultContentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)
        configure(window)
        webView = makeWebView()
        assembleLayers(in: window)
        watchDragClicks()
        webView.load(URLRequest(url: config.serverURL))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) no se usa")
    }

    // MARK: - Armado

    private func configure(_ window: NSWindow) {
        window.title = AppConfig.appName
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        // Vacía: no muestra nada ni se queda con los clics sobre la página (probado con hitTest).
        window.toolbar = NSToolbar(identifier: Self.toolbarIdentifier)
        window.toolbarStyle = .unified
        window.titlebarSeparatorStyle = .none
        window.isOpaque = false
        window.backgroundColor = .clear
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.contentMinSize = Self.minimumContentSize
        window.delegate = self
        if !window.setFrameUsingName(Self.frameAutosaveName) {
            window.center()
        }
        window.setFrameAutosaveName(Self.frameAutosaveName)
    }

    private func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.preferences.isElementFullscreenEnabled = true
        configuration.userContentController.add(self, name: Self.messageHandlerName)

        let webView = WKWebView(frame: .zero, configuration: configuration)
        // Transparente: donde la página no pinta fondo se ven el vidrio y la ventana.
        webView.setValue(false, forKey: "drawsBackground")
        webView.underPageBackgroundColor = .clear
        webView.allowsBackForwardNavigationGestures = true
        webView.isInspectable = true
        webView.navigationDelegate = self
        webView.uiDelegate = self
        installUserScripts(on: configuration.userContentController)
        return webView
    }

    private func assembleLayers(in window: NSWindow) {
        let container = FlippedView()
        window.contentView = container

        base.wantsLayer = true
        base.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        base.frame = container.bounds
        base.autoresizingMask = [.width, .height]

        sidebarBackdrop.material = .sidebar
        sidebarBackdrop.blendingMode = .behindWindow
        sidebarBackdrop.state = .followsWindowActiveState
        sidebarBackdrop.isHidden = true

        sidebarGlass.style = .regular
        sidebarClip.wantsLayer = true
        sidebarClip.layer?.masksToBounds = true
        sidebarClip.layer?.cornerCurve = .continuous
        sidebarClip.isHidden = true
        sidebarClip.addSubview(sidebarGlass)

        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]

        container.addSubview(base)
        container.addSubview(sidebarBackdrop)
        container.addSubview(sidebarClip)
        container.addSubview(webView)
    }

    private func installUserScripts(on controller: WKUserContentController) {
        controller.removeAllUserScripts()
        WebResources.userScripts().forEach(controller.addUserScript)
    }

    /// Sin barra de título nativa, la ventana se mueve desde las partes vacías de las barras de
    /// Paperclip. glass.js avisa al mover el puntero si está sobre una; aquí se decide en el clic mismo,
    /// que es lo que necesita `performDrag`.
    private func watchDragClicks() {
        mouseDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self, self.shouldDragWindow(for: event), let window = event.window else { return event }
            if event.clickCount == 2 {
                Self.titleBarDoubleClick(in: window)
            } else {
                window.performDrag(with: event)
            }
            return nil
        }
    }

    private func shouldDragWindow(for event: NSEvent) -> Bool {
        guard pointerOverDragArea, event.window === window,
              let contentView = window?.contentView,
              let frameView = contentView.superview
        else { return false }
        // Solo si el clic cae en la página: no en los botones de la ventana ni en el de la versión.
        let hit = frameView.hitTest(frameView.convert(event.locationInWindow, from: nil))
        return hit.map { $0 === webView || $0.isDescendant(of: webView) } ?? false
    }

    /// Lo que pide Ajustes del Sistema para el doble clic en una barra de título.
    private static func titleBarDoubleClick(in window: NSWindow) {
        switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
        case "Minimize": window.performMiniaturize(nil)
        case "None": break
        default: window.zoom(nil)
        }
    }

    // MARK: - Lo que usan el AppDelegate y UpdateController

    func reload() {
        webView.reload()
    }

    /// Tocar un aviso: trae la ventana y abre lo que avisó.
    func openNotification(href: String?) {
        showWindow(nil)
        NSApp.activate()
        guard let href else { return }
        Task {
            _ = try? await webView.callAsyncJavaScript(
                "window.__paperclipNative?.navigate(href)",
                arguments: ["href": href],
                contentWorld: .page
            )
        }
    }

    /// La apariencia de la app cambió (Ajustes o la Mac): la página la sigue.
    func setPageTheme(dark: Bool) {
        evaluate("window.__paperclipNative?.setTheme(\(WebResources.jsonLiteral(dark ? "dark" : "light")))")
    }

    /// Si se está mirando Paperclip: la ventana al frente y visible.
    var isInFront: Bool {
        guard let window else { return false }
        return NSApp.isActive && window.isKeyWindow && window.occlusionState.contains(.visible)
    }

    /// Muestra u oculta el botón de la versión, arriba a la derecha, centrado en la barra de la ruta.
    /// La página le deja ese espacio (glass.css, data-paperclip-app-version).
    func setUpdateButton(_ button: NSButton, visible: Bool) {
        guard let container = window?.contentView else { return }
        if updateButton !== button {
            updateButton = button
            button.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(button, positioned: .above, relativeTo: webView)
            let centerY = button.centerYAnchor.constraint(equalTo: container.topAnchor)
            updateButtonCenterY = centerY
            NSLayoutConstraint.activate([
                button.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Self.accessoryMargin),
                centerY,
            ])
        }
        updateButtonWanted = visible
        refreshUpdateButton()
    }

    /// Hasta que glass.js informa el alto de la barra, el botón no tiene dónde centrarse.
    private func refreshUpdateButton() {
        guard let updateButton else { return }
        updateButtonCenterY?.constant = topBarHeight / 2
        updateButton.isHidden = !updateButtonWanted || !pageIsDesktop || topBarHeight == 0
        syncPageState()
    }

    func present(_ alert: NSAlert) async -> NSApplication.ModalResponse {
        guard let window, window.isVisible else { return alert.runModal() }
        return await alert.beginSheetModal(for: window)
    }

    // MARK: - Visualización

    @objc func zoomIn(_ sender: Any?) { setPageZoom(webView.pageZoom + Self.zoomStep) }
    @objc func zoomOut(_ sender: Any?) { setPageZoom(webView.pageZoom - Self.zoomStep) }
    @objc func resetZoom(_ sender: Any?) { setPageZoom(1) }

    private func setPageZoom(_ value: CGFloat) {
        webView.pageZoom = min(max(value, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
    }

    // MARK: - Estado que la página necesita saber

    /// Pantalla completa (sin botones de ventana) y espacio para el botón de la versión.
    private func syncPageState() {
        let fullscreen = window?.styleMask.contains(.fullScreen) == true
        let updateWidth = updateButton.flatMap { $0.isHidden ? nil : $0.fittingSize.width + Self.accessoryMargin * 2 }
        let zoom = max(webView.pageZoom, 0.01)
        evaluate("""
            (() => {
              const root = document.documentElement;
              root.toggleAttribute("data-paperclip-app-fullscreen", \(fullscreen));
              root.toggleAttribute("data-paperclip-app-version", \(updateWidth != nil));
              root.style.setProperty("--paperclip-app-version-width", "\(Int(((updateWidth ?? 0) / zoom).rounded()))px");
            })();
            """)
    }

    private func evaluate(_ script: String) {
        webView.evaluateJavaScript(script, completionHandler: nil)
    }

    // MARK: - Mensajes de la página

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        // Solo desde este Paperclip: un iframe de otro sitio no le habla a la app.
        let origin = message.frameInfo.securityOrigin
        guard origin.protocol == config.serverURL.scheme, origin.host == config.serverURL.host(),
              origin.port == (config.serverURL.port ?? 0),
              let body = message.body as? [String: Any], let type = body["type"] as? String
        else { return }

        switch type {
        case "themeChosen":
            guard let theme = body["theme"] as? String else { return }
            onThemeChosen?(theme == "dark")
        case "layout":
            applyLayout(body)
        case "dragArea":
            pointerOverDragArea = body["value"] as? Bool ?? false
        default:
            break
        }
    }

    private func applyLayout(_ body: [String: Any]) {
        if let rgb = body["background"] as? [NSNumber], rgb.count == 3 {
            base.layer?.backgroundColor = NSColor(
                srgbRed: rgb[0].doubleValue / 255, green: rgb[1].doubleValue / 255, blue: rgb[2].doubleValue / 255,
                alpha: 1
            ).cgColor
        }
        // La página mide en píxeles CSS; con zoom, cada uno ocupa más puntos de la ventana.
        let zoom = webView.pageZoom
        let desktop = body["desktop"] as? Bool ?? true
        if let topBar = (body["topBar"] as? NSNumber)?.doubleValue, topBar * zoom != topBarHeight || desktop != pageIsDesktop {
            topBarHeight = topBar * zoom
            pageIsDesktop = desktop
            refreshUpdateButton()
        }
        guard let sidebar = body["sidebar"] as? [String: Any],
              let x = (sidebar["x"] as? NSNumber)?.doubleValue,
              let y = (sidebar["y"] as? NSNumber)?.doubleValue,
              let width = (sidebar["width"] as? NSNumber)?.doubleValue,
              let height = (sidebar["height"] as? NSNumber)?.doubleValue
        else {
            setSidebarPanel(nil, radius: 0)
            return
        }
        let inset = ((sidebar["inset"] as? NSNumber)?.doubleValue ?? 0) * zoom
        let frame = CGRect(x: x * zoom, y: y * zoom, width: width * zoom, height: height * zoom)
            .insetBy(dx: inset, dy: inset)
        setSidebarPanel(frame, radius: ((sidebar["radius"] as? NSNumber)?.doubleValue ?? 0) * zoom)
    }

    /// Ubica el panel de la barra lateral (material translúcido + vidrio), o lo esconde con `nil`.
    private func setSidebarPanel(_ frame: CGRect?, radius: CGFloat) {
        guard let frame, frame.width > 0, frame.height > 0 else {
            sidebarBackdrop.isHidden = true
            sidebarClip.isHidden = true
            return
        }
        if radius != sidebarRadius {
            sidebarRadius = radius
            sidebarGlass.cornerRadius = radius
            sidebarClip.layer?.cornerRadius = radius
            sidebarBackdrop.maskImage = Self.roundedMask(radius: radius)
        }
        for view in [sidebarBackdrop, sidebarClip] {
            view.frame = frame
            // Entre un aviso de glass.js y el siguiente, el panel sigue el alto de la ventana. Recién
            // ahora: con tamaño cero y alto flexible, macOS agranda la ventana 10 puntos cada vez que se abre.
            view.autoresizingMask = [.height]
            view.isHidden = false
        }
        sidebarGlass.frame = sidebarClip.bounds
        sidebarGlass.autoresizingMask = [.width, .height]
    }

    /// Máscara de esquinas redondeadas para el material translúcido, que se estira sin deformar las esquinas.
    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }

    // MARK: - Navegación

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async
        -> WKNavigationActionPolicy
    {
        if navigationAction.shouldPerformDownload { return .download }
        guard let url = navigationAction.request.url else { return .allow }
        let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? true
        if !isMainFrame || config.isInternal(url) || ["about", "blob", "data"].contains(url.scheme ?? "") {
            return .allow
        }
        // Lo que no es de Paperclip se abre en el navegador por defecto.
        NSWorkspace.shared.open(url)
        return .cancel
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async
        -> WKNavigationResponsePolicy
    {
        navigationResponse.canShowMIMEType ? .allow : .download
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = downloads
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = downloads
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        syncPageState()
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }

    // MARK: - Ventanas nuevas, archivos y diálogos de la página

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        // Paperclip en una sola ventana: lo suyo se abre aquí y lo de afuera en el navegador.
        if let url = navigationAction.request.url {
            if config.isInternal(url) {
                webView.load(navigationAction.request)
            } else {
                NSWorkspace.shared.open(url)
            }
        }
        return nil
    }

    func webView(
        _ webView: WKWebView,
        runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo
    ) async -> [URL]? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        guard let window else { return panel.runModal() == .OK ? panel.urls : nil }
        return await panel.beginSheetModal(for: window) == .OK ? panel.urls : nil
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo
    ) async {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "Aceptar")
        _ = await present(alert)
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo
    ) async -> Bool {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "Aceptar")
        alert.addButton(withTitle: "Cancelar")
        return await present(alert) == .alertFirstButtonReturn
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo
    ) async -> String? {
        let alert = NSAlert()
        alert.messageText = prompt
        let field = NSTextField(string: defaultText ?? "")
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Aceptar")
        alert.addButton(withTitle: "Cancelar")
        return await present(alert) == .alertFirstButtonReturn ? field.stringValue : nil
    }

    // MARK: - Ventana

    /// Cerrar esconde la ventana: la app sigue contando y avisando. Cmd+Q la cierra del todo.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }

    /// En pantalla completa la barra de herramientas vacía se quedaría fija arriba, tapando la página: así
    /// se esconde y aparece junto con la barra de menús, como en Safari.
    func window(
        _ window: NSWindow,
        willUseFullScreenPresentationOptions proposedOptions: NSApplication.PresentationOptions = []
    ) -> NSApplication.PresentationOptions {
        proposedOptions.union([.fullScreen, .autoHideMenuBar, .autoHideToolbar])
    }

    /// Detrás de una ventana en pantalla completa solo queda el fondo de pantalla, que teñiría el panel (y
    /// aparece y desaparece al cambiar de escritorio): ahí el material toma el fondo de la propia ventana.
    func windowWillEnterFullScreen(_ notification: Notification) {
        sidebarBackdrop.blendingMode = .withinWindow
    }

    func windowDidEnterFullScreen(_ notification: Notification) { syncPageState() }

    func windowWillExitFullScreen(_ notification: Notification) {
        sidebarBackdrop.blendingMode = .behindWindow
    }

    func windowDidExitFullScreen(_ notification: Notification) { syncPageState() }
}
