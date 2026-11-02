import AppKit
import SwiftUI
import WebKit

/// Contenedor con el origen arriba a la izquierda, como la página: los rectángulos que manda layout.js
/// se usan tal cual.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// La ventana de Paperclip. La página la ocupa entera, sin barra de título: los botones de la ventana
/// quedan sobre la barra lateral de Paperclip, que les hace lugar (layout.css), y la ventana se mueve desde
/// las partes vacías de sus barras de arriba (layout.js). La barra de herramientas va vacía: da las
/// esquinas de ventana de macOS 26. El botón de la versión flota sobre la barra de la ruta de Paperclip,
/// solo en el Dashboard. El gesto de atrás y adelante es el de la app (`PaperclipWebView`): la página no
/// se mueve y entra una flecha desde el borde. Con un archivo abierto en vez de Paperclip (un PDF adjunto),
/// junto a los botones de la ventana sale uno de atrás.
///
/// Con **Liquid Glass** (experimental, Ajustes → General), además, la barra lateral y el panel de propiedades
/// de una tarea van sobre vidrio, en capas:
/// 1. Un fondo del mismo color que el de Paperclip: alrededor de los paneles no se nota otro gris.
/// 2. Los paneles de vidrio (`GlassPanel`), donde layout.js dice que están los de Paperclip.
/// 3. La página, transparente donde glass.css le quita el fondo.
@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate,
    WKScriptMessageHandler, NSMenuItemValidation
{
    private static let frameAutosaveName = "PaperclipMainWindow"
    private static let toolbarIdentifier = "PaperclipMainToolbar"
    private static let messageHandlerName = "paperclipDispatch"
    private static let defaultContentSize = NSSize(width: 1440, height: 900)
    private static let minimumContentSize = NSSize(width: 520, height: 420)
    private static let zoomRange: ClosedRange<CGFloat> = 0.5...2
    private static let zoomStep: CGFloat = 0.1
    /// Separación del botón de la versión con el borde derecho, y del de atrás con lo que tiene a la izquierda.
    private static let accessoryMargin: CGFloat = 16
    /// Lo que la ventana muestra como página web; lo demás (un PDF, una imagen, un texto) es un archivo.
    private static let webPageTypes: Set<String> = ["text/html", "application/xhtml+xml"]
    /// Aire sobre el texto al que se desplaza el ensayo de páginas, en píxeles de la página.
    private static let anchorMargin = 24
    /// Lo que responde un proxy cuando Paperclip no está detrás.
    private static let unavailableStatusCodes: Set<Int> = [502, 503, 504]
    /// Cada cuánto se vuelve a probar un Paperclip que no responde.
    private static let offlineRetryInterval: Duration = .seconds(3)
    /// WebKit corta la carga cuando la respuesta se vuelve descarga (WebKitErrorFrameLoadInterruptedByPolicyChange).
    private static let interruptedByPolicyCode = 102
    /// Lo que se le ofrece a una hoja para que diga cuánto mide.
    static let unboundedSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
    /// Separación de lo que flota abajo (el recordatorio de avisos) con el borde de la ventana.
    private static let bottomOverlayMargin: CGFloat = 26
    /// Direcciones que arma la propia página (about:blank, blob:, data:): se quedan en la ventana.
    private static let pageOwnedSchemes: Set<String> = ["about", "blob", "data"]
    /// El campo de texto de un `prompt()` de la página.
    private static let promptFieldSize = NSSize(width: 280, height: 24)

    private let config: AppConfig
    /// Si la página va sobre Liquid Glass (el modo experimental).
    private var glass: Bool

    private let base = NSView()
    /// Con vidrio, detrás de la barra lateral de Paperclip y del panel de propiedades de una tarea.
    private let sidebarPanel = GlassPanel(edge: .leading)
    private let inspectorPanel = GlassPanel(edge: .trailing)
    private let downloads = DownloadHandler()
    /// La IA integrada de Chrome que buscan algunos plugins, con el modelo de Apple (language-model.js).
    private let languageModel: LanguageModelBridge
    private var webView: PaperclipWebView!
    /// La flecha del gesto de atrás y adelante, sobre la página.
    private let swipeIndicator = SwipeIndicator()
    private var pointerOverDragArea = false
    private var mouseDownMonitor: Any?

    private var updateButton: NSButton?
    private var updateButtonCenterY: NSLayoutConstraint?
    /// Atrás, junto a los botones de la ventana. Solo con un archivo abierto (un adjunto en PDF, por
    /// ejemplo): WebKit lo muestra en la ventana entera, sin Paperclip alrededor ni cómo volver.
    private let backButton = NSButton()
    private var backButtonLeading: NSLayoutConstraint?
    private var backButtonCenterY: NSLayoutConstraint?
    /// La ventana muestra un archivo y no una página (`refreshDocumentKind`).
    private var showingFile = false
    private var titleObservation: NSKeyValueObservation?
    private var urlObservation: NSKeyValueObservation?
    /// Lo que flota abajo y al centro, sobre la página (el recordatorio de avisos).
    private var bottomOverlay: NSView?
    /// Alto de las barras de arriba de Paperclip (--sz-60px), en puntos; lo informa layout.js.
    private var topBarHeight: CGFloat = 0
    /// En la vista angosta de Paperclip (móvil) la barra de arriba es otra y no hay lugar para el botón.
    private var pageIsDesktop = true
    /// El botón de la versión flota sobre la página y solo sale en el Dashboard (`/<company>/dashboard`):
    /// es la única página sin nada arriba a la derecha. En las otras ahí van botones de Paperclip, o el
    /// panel de propiedades de una tarea, que llega hasta arriba.
    private static let pageWithFreeCorner = "dashboard"
    private var pageHasFreeCorner: Bool { webView.url?.lastPathComponent == Self.pageWithFreeCorner }

    private let offline = OfflineModel()
    private var offlineView: NSView?
    private var offlineWatch: Task<Void, Never>?
    /// La página que no cargó, para volver a ella cuando Paperclip responda.
    private var failedURL: URL?

    /// Se eligió el tema en el menú de Paperclip (true = oscuro): la app lo adopta como ajuste.
    var onThemeChosen: ((_ dark: Bool) -> Void)?
    /// La página cambió de dirección (también sin recargar, como al iniciar sesión).
    var onPageChange: (() -> Void)?
    /// «Cambiar dirección…» cuando Paperclip no responde.
    var onChangeServer: (() -> Void)? {
        get { offline.onChangeServer }
        set { offline.onChangeServer = newValue }
    }

    /// `rehearsal`: para los ensayos, que la ponen fuera de la pantalla. No lee ni guarda dónde quedó la
    /// ventana. `initialURL`: la página con que abre (la que estaba al reiniciar para actualizar); sin ella,
    /// el inicio de Paperclip.
    init(config: AppConfig, liquidGlass: Bool, rehearsal: Bool = false, initialURL: URL? = nil) {
        self.config = config
        glass = liquidGlass
        languageModel = LanguageModelBridge(allows: { [config] in Self.isPaperclip($0, config: config) })
        let window = SnapshotableWindow(
            contentRect: NSRect(origin: .zero, size: Self.defaultContentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)
        configure(window, remembersFrame: !rehearsal)
        webView = makeWebView()
        assembleLayers(in: window)
        applyMode()
        watchDragClicks()
        titleObservation = webView.observe(\.title) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.updateTitle() }
        }
        urlObservation = webView.observe(\.url) { [weak self] _, _ in
            MainActor.assumeIsolated {
                self?.refreshUpdateButton()
                self?.refreshDocumentKind()
                self?.onPageChange?()
            }
        }
        webView.load(URLRequest(url: initialURL ?? config.serverURL))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    // MARK: - Armado

    private func configure(_ window: NSWindow, remembersFrame: Bool) {
        window.title = AppConfig.appName
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.contentMinSize = Self.minimumContentSize
        window.delegate = self
        // Sin título (la página ya dice dónde estás) y con la barra de título transparente, sobre la página.
        // La barra de herramientas vacía no muestra nada ni se queda con los clics sobre la página (probado
        // con hitTest): solo da las esquinas de macOS 26 y la altura de los botones de la ventana.
        window.toolbar = NSToolbar(identifier: Self.toolbarIdentifier)
        window.toolbarStyle = .unified
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        guard remembersFrame else { return }
        if !window.setFrameUsingName(Self.frameAutosaveName) {
            window.center()
        }
        window.setFrameAutosaveName(Self.frameAutosaveName)
    }

    private func makeWebView() -> PaperclipWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.preferences.isElementFullscreenEnabled = true
        configuration.userContentController.add(self, name: Self.messageHandlerName)
        configuration.userContentController.addScriptMessageHandler(
            languageModel, contentWorld: .page, name: LanguageModelBridge.handlerName
        )

        let webView = PaperclipWebView(frame: .zero, configuration: configuration)
        webView.isInspectable = true
        webView.onSwipe = { [weak self] swipe in self?.swipeIndicator.update(swipe) }
        webView.navigationDelegate = self
        webView.uiDelegate = self
        return webView
    }

    private func assembleLayers(in window: NSWindow) {
        let container = FlippedView()
        window.contentView = container

        // El color lo pone applyMode, y después el que informa layout.js.
        base.wantsLayer = true
        base.frame = container.bounds
        base.autoresizingMask = [.width, .height]

        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]

        container.addSubview(base)
        container.addSubview(webView)
        sidebarPanel.install(in: container, below: webView)
        inspectorPanel.install(in: container, below: webView)

        let indicator = PassthroughHostingView(rootView: SwipeIndicatorView(model: swipeIndicator))
        indicator.frame = container.bounds
        indicator.autoresizingMask = [.width, .height]
        container.addSubview(indicator)

        backButton.bezelStyle = .glass
        backButton.controlSize = .large
        backButton.image = NSImage(systemSymbolName: "chevron.backward", accessibilityDescription: String(localized: "Back"))
        backButton.toolTip = String(localized: "Back")
        backButton.target = self
        backButton.action = #selector(navigateBack(_:))
        backButton.isHidden = true
        backButton.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(backButton)
        let leading = backButton.leadingAnchor.constraint(equalTo: container.leadingAnchor)
        let centerY = backButton.centerYAnchor.constraint(equalTo: container.topAnchor)
        NSLayoutConstraint.activate([leading, centerY])
        backButtonLeading = leading
        backButtonCenterY = centerY
    }

    /// Lo que cambia con Liquid Glass. La página toma los scripts nuevos al recargar.
    private func applyMode() {
        guard let window else { return }
        // Con vidrio, ventana y página transparentes: donde la página no pinta fondo se ven el vidrio y lo
        // que hay detrás de la ventana.
        window.isOpaque = !glass
        window.backgroundColor = glass ? .clear : .windowBackgroundColor
        webView.setValue(!glass, forKey: "drawsBackground")
        webView.underPageBackgroundColor = glass ? .clear : nil
        webView.pageScrollsBack = false
        webView.pageScrollsForward = false
        base.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        sidebarPanel.place(nil, radius: 0)
        inspectorPanel.place(nil, radius: 0)
        topBarHeight = 0
        pageIsDesktop = true
        pointerOverDragArea = false
        let controller = webView.configuration.userContentController
        controller.removeAllUserScripts()
        WebResources.userScripts(glass: glass).forEach(controller.addUserScript)
        refreshUpdateButton()
    }

    /// El botón de la versión flota sobre la página, a la derecha de la barra de la ruta de Paperclip, que le
    /// deja el espacio (layout.css, data-paperclip-dispatch-version).
    private func placeUpdateButton() {
        updateButtonCenterY = nil
        guard let updateButton, let container = window?.contentView else { return }
        updateButton.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(updateButton, positioned: .above, relativeTo: webView)
        let centerY = updateButton.centerYAnchor.constraint(equalTo: container.topAnchor)
        updateButtonCenterY = centerY
        NSLayoutConstraint.activate([
            updateButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Self.accessoryMargin),
            centerY,
        ])
        refreshUpdateButton()
    }

    /// El título de la página, como en un navegador: no se muestra en la barra, pero lo usan el menú Ventana,
    /// Mission Control y VoiceOver.
    private func updateTitle() {
        let title = webView.title?.trimmingCharacters(in: .whitespaces) ?? ""
        window?.title = title.isEmpty ? AppConfig.appName : title
    }

    /// Sin barra de título, la ventana se mueve desde las partes vacías de las barras de arriba de Paperclip.
    /// layout.js avisa al mover el puntero si está sobre una; aquí se decide en el clic mismo, que es lo que
    /// necesita `performDrag`.
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

    /// Con un archivo abierto, la franja de arriba (la de los botones) hace de barra de título.
    private func shouldDragWindow(for event: NSEvent) -> Bool {
        guard event.window === window, let contentView = window?.contentView,
              let frameView = contentView.superview
        else { return false }
        let overFileStrip = showingFile
            && contentView.convert(event.locationInWindow, from: nil).y < webView.obscuredContentInsets.top
        guard pointerOverDragArea || overFileStrip else { return false }
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
        if offlineView != nil {
            retryOffline()
        } else {
            webView.reload()
        }
    }

    /// Abre una ruta de Paperclip (p. ej. `/<prefijo>/agent-usage`) cargando la página de nuevo. Para el ensayo
    /// de páginas.
    func load(path: String) {
        webView.load(URLRequest(url: config.serverURL.appending(path: path)))
    }

    /// Desplaza la página hasta el primer texto que empiece así, con un poco de aire arriba. Para el ensayo
    /// de páginas; devuelve si lo encontró.
    func scrollPage(toText text: String) async -> Bool {
        let result = try? await webView.callAsyncJavaScript(
            """
            const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
            let target = null;
            // React parte el texto en varios nodos («Cada semana», « de », la cuenta): se mira el del padre.
            while (!target && walker.nextNode()) {
              const parent = walker.currentNode.parentElement;
              if (parent?.textContent.trim().startsWith(text)) target = parent;
            }
            if (!target) return false;
            target.scrollIntoView({ block: "start" });
            let scroller = target.parentElement;
            while (scroller && !(scroller.scrollHeight > scroller.clientHeight
              && /(auto|scroll)/.test(getComputedStyle(scroller).overflowY))) scroller = scroller.parentElement;
            (scroller ?? document.scrollingElement).scrollBy(0, -margin);
            return true;
            """,
            arguments: ["text": text, "margin": Self.anchorMargin],
            contentWorld: .page
        )
        return result as? Bool ?? false
    }

    /// Ajustes → General → Experimental. Cambia la ventana y recarga la página con los scripts del modo.
    func setLiquidGlass(_ enabled: Bool) {
        guard enabled != glass else { return }
        glass = enabled
        applyMode()
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

    /// La página abierta, para volver a ella después de reiniciar.
    var pageURL: URL? { failedURL ?? webView.url }

    /// Si se está mirando Paperclip: la ventana al frente y visible.
    var isInFront: Bool {
        guard let window else { return false }
        return NSApp.isActive && window.isKeyWindow && window.occlusionState.contains(.visible)
    }

    /// Pone el botón de la versión, arriba a la derecha: centrado en la barra de la ruta de Paperclip y visible
    /// solo en el Dashboard (`pageWithFreeCorner`).
    func setUpdateButton(_ button: NSButton) {
        if updateButton !== button {
            updateButton?.removeFromSuperview()
            updateButton = button
            placeUpdateButton()
        } else {
            refreshUpdateButton()
        }
    }

    /// Dónde están los botones de la ventana, en puntos desde arriba a la izquierda; `nil` en pantalla completa,
    /// donde no se ven.
    private var windowButtonsFrame: CGRect? {
        guard let window, !window.styleMask.contains(.fullScreen), let container = window.contentView,
              let close = window.standardWindowButton(.closeButton),
              let zoom = window.standardWindowButton(.zoomButton)
        else { return nil }
        let frame = close.convert(close.bounds, to: nil).union(zoom.convert(zoom.bounds, to: nil))
        return container.convert(frame, from: nil)
    }

    /// Si la ventana muestra un archivo en vez de una página. WebKit abre ahí mismo lo que Paperclip enlaza y
    /// sabe mostrar (un adjunto en PDF, una imagen o un texto), y eso no trae cómo volver: se ofrece el botón
    /// de atrás. Se pregunta al documento porque al volver desde la caché de páginas no hay respuesta que mirar.
    private func refreshDocumentKind() {
        webView.evaluateJavaScript("document.contentType") { [weak self] result, _ in
            guard let type = result as? String else { return }
            MainActor.assumeIsolated { self?.setShowingFile(!Self.webPageTypes.contains(type)) }
        }
    }

    private func setShowingFile(_ value: Bool) {
        showingFile = value
        // Un archivo no tiene layout.js: no hay barras desde donde mover la ventana.
        if value { pointerOverDragArea = false }
        refreshBackButton()
    }

    /// Junto a los botones de la ventana y a su altura; en pantalla completa, en la esquina. Con un archivo, la
    /// franja de esos botones queda fuera de lo que WebKit muestra (`obscuredContentInsets`), para que el
    /// archivo no empiece debajo de ellos. Paperclip va hasta arriba: él les hace lugar (layout.css).
    private func refreshBackButton() {
        backButton.isHidden = !showingFile || offlineView != nil
        var insets = NSEdgeInsetsZero
        if showingFile {
            if let buttons = windowButtonsFrame {
                backButtonLeading?.constant = buttons.maxX + Self.accessoryMargin
                backButtonCenterY?.constant = buttons.midY
            } else {
                backButtonLeading?.constant = Self.accessoryMargin
                backButtonCenterY?.constant = Self.accessoryMargin + backButton.fittingSize.height / 2
            }
            insets.top = (backButtonCenterY?.constant ?? 0) * 2
        }
        // Cambiarlas hace que WebKit vuelva a acomodar la página: solo si cambian.
        if !NSEdgeInsetsEqual(webView.obscuredContentInsets, insets) {
            webView.obscuredContentInsets = insets
        }
    }

    /// Hasta que layout.js informa el alto de la barra, el botón no tiene dónde centrarse.
    private func refreshUpdateButton() {
        guard let updateButton else { return }
        updateButtonCenterY?.constant = topBarHeight / 2
        updateButton.isHidden = !pageIsDesktop || topBarHeight == 0 || !pageHasFreeCorner
        syncPageState()
    }

    func present(_ alert: NSAlert) async -> NSApplication.ModalResponse {
        guard let window, window.isVisible else { return alert.runModal() }
        return await alert.beginSheetModal(for: window)
    }

    /// Si se puede mostrar algo encima sin interrumpir: se está mirando la ventana, sin hojas abiertas y con
    /// Paperclip cargado.
    var canPresentOverlay: Bool {
        isInFront && window?.attachedSheet == nil && offlineView == nil
    }

    /// Una vista de SwiftUI como hoja de la ventana (las sugerencias). Se cierra con `dismissSheet`.
    func presentSheet(_ content: some View) -> NSWindow? {
        guard let window else { return nil }
        // Del tamaño de lo de adentro, medido una vez: con `.preferredContentSize` la hoja y AppKit se
        // reacomodan sin fin y la app se cae.
        let hosting = NSHostingController(rootView: content)
        hosting.sizingOptions = []
        let sheet = NSWindow(contentViewController: hosting)
        sheet.setContentSize(hosting.sizeThatFits(in: Self.unboundedSize))
        window.beginSheet(sheet)
        return sheet
    }

    func dismissSheet(_ sheet: NSWindow) {
        window?.endSheet(sheet)
    }

    /// Pone una vista abajo y al centro, sobre la página. Ocupa solo lo que mide, así que el resto de la
    /// página sigue recibiendo los clics. Con la vista sin conexión se esconde. `padding`: el aire que la
    /// vista deja alrededor para su sombra, que no cuenta para la separación con el borde.
    func setBottomOverlay(_ content: some View, padding: CGFloat = 0) {
        bottomOverlay?.removeFromSuperview()
        guard let container = window?.contentView else { return }
        let hosting = NSHostingView(rootView: content)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(hosting, positioned: .above, relativeTo: offlineView ?? webView)
        NSLayoutConstraint.activate([
            hosting.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            hosting.bottomAnchor.constraint(
                equalTo: container.bottomAnchor,
                constant: -Self.bottomOverlayMargin + padding
            ),
        ])
        hosting.isHidden = offlineView != nil
        bottomOverlay = hosting
    }

    // MARK: - Visualización

    @objc func zoomIn(_ sender: Any?) { setPageZoom(webView.pageZoom + Self.zoomStep) }
    @objc func zoomOut(_ sender: Any?) { setPageZoom(webView.pageZoom - Self.zoomStep) }
    @objc func resetZoom(_ sender: Any?) { setPageZoom(1) }

    private func setPageZoom(_ value: CGFloat) {
        webView.pageZoom = min(max(value, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
    }

    // MARK: - Archivo e Ir

    /// La dirección de la página, como texto y como enlace.
    @objc func copyPageLink(_ sender: Any?) {
        guard let url = pageURL else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.declareTypes([.URL, .string], owner: nil)
        pasteboard.setString(url.absoluteString, forType: .URL)
        pasteboard.setString(url.absoluteString, forType: .string)
    }

    @objc func openPageInBrowser(_ sender: Any?) {
        guard let url = pageURL else { return }
        NSWorkspace.shared.open(url)
    }

    @objc func navigateBack(_ sender: Any?) { webView.goBack() }
    @objc func navigateForward(_ sender: Any?) { webView.goForward() }

    /// El inicio de Paperclip, que lleva al Dashboard de la company.
    @objc func goHome(_ sender: Any?) {
        webView.load(URLRequest(url: config.serverURL))
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(navigateBack(_:)): offlineView == nil && webView.canGoBack
        case #selector(navigateForward(_:)): offlineView == nil && webView.canGoForward
        case #selector(copyPageLink(_:)), #selector(openPageInBrowser(_:)): pageURL != nil
        default: true
        }
    }

    // MARK: - Estado que la página necesita saber

    /// Pantalla completa (sin botones de ventana), dónde están esos botones y espacio para el botón de la
    /// versión.
    private func syncPageState() {
        let fullscreen = window?.styleMask.contains(.fullScreen) == true
        let updateWidth = updateButton.flatMap { $0.isHidden ? nil : $0.fittingSize.width + Self.accessoryMargin * 2 }
        let zoom = max(webView.pageZoom, 0.01)
        let css = { (points: CGFloat) in "\(Int((points / zoom).rounded()))px" }
        let buttons = windowButtonsFrame ?? .zero
        evaluate("""
            (() => {
              const root = document.documentElement;
              root.toggleAttribute("data-paperclip-dispatch-fullscreen", \(fullscreen));
              root.toggleAttribute("data-paperclip-dispatch-version", \(updateWidth != nil));
              root.style.setProperty("--paperclip-dispatch-version-width", "\(css(updateWidth ?? 0))");
              root.style.setProperty("--paperclip-dispatch-window-buttons-end", "\(css(buttons.maxX))");
              root.style.setProperty("--paperclip-dispatch-window-buttons-middle", "\(css(buttons.midY))");
            })();
            """)
    }

    private func evaluate(_ script: String) {
        webView.evaluateJavaScript(script, completionHandler: nil)
    }

    // MARK: - Mensajes de la página

    /// Si un mensaje viene de este Paperclip: un iframe de otro sitio no le habla a la app.
    private static func isPaperclip(_ origin: WKSecurityOrigin, config: AppConfig) -> Bool {
        origin.protocol == config.serverURL.scheme && origin.host == config.serverURL.host()
            && origin.port == (config.serverURL.port ?? 0)
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard Self.isPaperclip(message.frameInfo.securityOrigin, config: config),
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
        case "horizontalScroll":
            webView.pageScrollsBack = body["back"] as? Bool ?? false
            webView.pageScrollsForward = body["forward"] as? Bool ?? false
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
        // Los paneles de vidrio, solo con Liquid Glass.
        guard glass else {
            sidebarPanel.place(nil, radius: 0)
            inspectorPanel.place(nil, radius: 0)
            return
        }
        let inset = ((body["inset"] as? NSNumber)?.doubleValue ?? 0) * zoom
        let radius = ((body["radius"] as? NSNumber)?.doubleValue ?? 0) * zoom
        sidebarPanel.place(Self.panelFrame(body["sidebar"], zoom: zoom, inset: inset), radius: radius)
        inspectorPanel.place(Self.panelFrame(body["inspector"], zoom: zoom, inset: inset), radius: radius)
    }

    /// Un rectángulo de layout.js, en puntos de la ventana y con el margen del panel; `nil` si no hay.
    private static func panelFrame(_ value: Any?, zoom: CGFloat, inset: CGFloat) -> CGRect? {
        guard let rect = value as? [String: Any],
              let x = (rect["x"] as? NSNumber)?.doubleValue,
              let y = (rect["y"] as? NSNumber)?.doubleValue,
              let width = (rect["width"] as? NSNumber)?.doubleValue,
              let height = (rect["height"] as? NSNumber)?.doubleValue
        else { return nil }
        return CGRect(x: x * zoom, y: y * zoom, width: width * zoom, height: height * zoom)
            .insetBy(dx: inset, dy: inset)
    }

    // MARK: - Navegación

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async
        -> WKNavigationActionPolicy
    {
        if navigationAction.shouldPerformDownload { return .download }
        guard let url = navigationAction.request.url else { return .allow }
        let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? true
        if !isMainFrame || config.isInternal(url) || Self.pageOwnedSchemes.contains(url.scheme ?? "") {
            return .allow
        }
        // Lo que no es de Paperclip se abre en el navegador por defecto.
        NSWorkspace.shared.open(url)
        return .cancel
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async
        -> WKNavigationResponsePolicy
    {
        // Con un proxy delante (tailscale serve, Caddy), Paperclip apagado no falla: responde 502.
        if navigationResponse.isForMainFrame, let http = navigationResponse.response as? HTTPURLResponse,
           Self.unavailableStatusCodes.contains(http.statusCode)
        {
            failedURL = http.url.flatMap { config.isInternal($0) ? $0 : nil } ?? config.serverURL
            showOffline(reason: String(localized: "It answered with error \(http.statusCode): Paperclip may be off behind it."))
            return .cancel
        }
        return navigationResponse.canShowMIMEType ? .allow : .download
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = downloads
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = downloads
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        languageModel.reset()
        refreshDocumentKind()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        hideOffline()
        syncPageState()
        refreshDocumentKind()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let error = error as NSError
        let interrupted = error.domain == "WebKitErrorDomain" && error.code == Self.interruptedByPolicyCode
        guard !(error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled), !interrupted else { return }
        let failing = error.userInfo[NSURLErrorFailingURLErrorKey] as? URL
        failedURL = failing.flatMap { config.isInternal($0) ? $0 : nil } ?? config.serverURL
        showOffline(reason: OfflineModel.reason(for: error))
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }

    // MARK: - Sin conexión

    /// Tapa la página con OfflineView y vuelve a probar sola hasta que Paperclip responda.
    private func showOffline(reason: String) {
        offline.serverURL = config.serverURL
        offline.reason = reason
        offline.startError = nil
        if offlineView == nil, let container = window?.contentView {
            let hosting = NSHostingView(rootView: OfflineView(model: offline))
            hosting.frame = container.bounds
            hosting.autoresizingMask = [.width, .height]
            container.addSubview(hosting, positioned: .above, relativeTo: webView)
            offlineView = hosting
            bottomOverlay?.isHidden = true
            refreshBackButton()
            // Sin página cargada, WKWebView se queda con los atajos (⌘, ⌘R…) y no se los pasa al menú.
            window?.makeFirstResponder(nil)
            webView.isHidden = true
        }
        Task { await findStoppedPaperclip() }
        watchOffline()
    }

    /// Si la dirección es la del Paperclip de esta Mac y está apagado, se ofrece encenderlo.
    private func findStoppedPaperclip() async {
        guard PaperclipLocator.isOnThisMac(config.serverURL) else {
            offline.local = nil
            return
        }
        if case let .stopped(local) = await PaperclipLocator.detect() {
            offline.local = local
        } else {
            offline.local = nil
        }
    }

    private func watchOffline() {
        offlineWatch?.cancel()
        offline.onRetry = { [weak self] in self?.retryOffline() }
        offlineWatch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.offlineRetryInterval)
                guard !Task.isCancelled, let self else { return }
                if case .success = await PaperclipLocator.probe(config.serverURL) {
                    retryOffline()
                    return
                }
            }
        }
    }

    private func retryOffline() {
        webView.load(URLRequest(url: failedURL ?? config.serverURL))
    }

    private func hideOffline() {
        offlineWatch?.cancel()
        offlineWatch = nil
        offline.starting = false
        guard let offlineView else { return }
        offlineView.removeFromSuperview()
        self.offlineView = nil
        bottomOverlay?.isHidden = false
        refreshBackButton()
        failedURL = nil
        webView.isHidden = false
        window?.makeFirstResponder(webView)
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
        alert.addButton(withTitle: String(localized: "OK"))
        _ = await present(alert)
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo
    ) async -> Bool {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: String(localized: "OK"))
        alert.addButton(withTitle: String(localized: "Cancel"))
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
        field.frame = NSRect(origin: .zero, size: Self.promptFieldSize)
        alert.accessoryView = field
        alert.addButton(withTitle: String(localized: "OK"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        return await present(alert) == .alertFirstButtonReturn ? field.stringValue : nil
    }

    // MARK: - Lo que WebKit solo le pide a Safari

    // WKUIDelegate no tiene métodos públicos para esto: son los de WKUIDelegatePrivate, que usa Safari. WebKit
    // pregunta si la app los tiene (respondsToSelector) antes de llamarlos, así que si un día cambian de
    // nombre, la app vuelve a lo de antes (sin capturar el puntero, sin guardar el PDF) y nada se rompe.

    /// Capturar el puntero (Pointer Lock), como la vista 3D de un plugin: sin este método WebKit siempre dice
    /// que no, y la página tiene que mirar arrastrando. Solo para Paperclip. La página lo pide con un clic y
    /// Esc lo suelta.
    @objc(_webViewDidRequestPointerLock:completionHandler:)
    func webViewDidRequestPointerLock(_ webView: WKWebView, completionHandler: @escaping (Bool) -> Void) {
        completionHandler(webView.url.map(config.isInternal) ?? false)
    }

    /// El botón de descargar del visor de PDF. Se pregunta dónde guardarlo, empezando por Descargas.
    @objc(_webView:saveDataToFile:suggestedFilename:mimeType:originatingURL:)
    func webView(
        _ webView: WKWebView,
        saveDataToFile data: Data?,
        suggestedFilename: String?,
        mimeType: String?,
        originatingURL: URL?
    ) {
        guard let data, let window else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedFilename ?? ""
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        Task {
            guard await panel.beginSheetModal(for: window) == .OK, let url = panel.url else { return }
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                _ = await present(NSAlert(error: error))
            }
        }
    }

    // MARK: - Ventana

    /// Cerrar esconde la ventana: la app sigue contando y avisando. Cmd+Q la cierra del todo.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }

    /// Lo que se ve arriba en pantalla completa aparece con la barra de menús, al llevar el puntero arriba, en
    /// vez de quedar fijo tapando la página.
    func window(
        _ window: NSWindow,
        willUseFullScreenPresentationOptions proposedOptions: NSApplication.PresentationOptions = []
    ) -> NSApplication.PresentationOptions {
        proposedOptions.union([.fullScreen, .autoHideMenuBar, .autoHideToolbar])
    }

    /// En pantalla completa la barra de herramientas vacía sobra (no hay esquinas que redondear) y, al llevar
    /// el puntero arriba, haría bajar una franja más alta que la de otras apps: se esconde y queda la barra
    /// de título normal. Detrás de la ventana solo queda el fondo de pantalla, que teñiría el panel (y aparece
    /// y desaparece al cambiar de escritorio): ahí el material toma el fondo de la propia ventana.
    func windowWillEnterFullScreen(_ notification: Notification) {
        window?.toolbar?.isVisible = false
        sidebarPanel.setBlendsWithinWindow(true)
        inspectorPanel.setBlendsWithinWindow(true)
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        syncPageState()
        refreshBackButton()
    }

    func windowWillExitFullScreen(_ notification: Notification) {
        sidebarPanel.setBlendsWithinWindow(false)
        inspectorPanel.setBlendsWithinWindow(false)
    }

    /// La barra de herramientas vuelve recién con la ventana fuera de pantalla completa: si vuelve durante la
    /// salida, macOS deja los botones de la ventana donde van sin ella, pegados a la esquina.
    func windowDidExitFullScreen(_ notification: Notification) {
        window?.toolbar?.isVisible = true
        syncPageState()
        refreshBackButton()
    }
}
