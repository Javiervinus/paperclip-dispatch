import AppKit
import SwiftUI

/// La bienvenida. La primera vez son tres pasos: qué es la app, conectar con Paperclip (lo encuentra en esta
/// Mac o ayuda a encenderlo, instalarlo o escribir la dirección de otro) y los avisos, que se piden después
/// de mostrar para qué sirven. Desde Ajustes → Paperclip → Cambiar… es solo el de conectar.
@MainActor
@Observable
final class WelcomeModel {
    enum Mode: Equatable {
        case firstRun
        case change(current: URL)
    }

    enum Phase: Int, Comparable {
        case intro, connect, notifications

        static func < (lhs: Phase, rhs: Phase) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    enum Step: Equatable {
        case searching
        case found(LocalPaperclip, PaperclipHealth)
        case stopped(LocalPaperclip)
        case notFound
        case address
        case install
    }

    enum NodeStatus: Equatable {
        case checking
        case missing
        case old(String)
        case ready(String)
    }

    /// Cada cuánto se vuelve a buscar mientras Paperclip arranca o se instala.
    private static let watchInterval: Duration = .seconds(2)

    let mode: Mode
    private(set) var phase: Phase
    /// Si el último cambio de paso fue hacia adelante, para que la animación vaya hacia ese lado.
    private(set) var movingForward = true
    var step: Step
    var address = ""
    var addressError: String?
    var checkingAddress = false
    var starting = false
    var startError: String?
    var node: NodeStatus = .checking
    var installerOpened = false
    /// El Paperclip elegido la primera vez: se conecta al terminar, después de los avisos.
    private(set) var chosenURL: URL?
    private(set) var notificationAccess: NotificationAccess?
    private(set) var requestingNotifications = false
    /// macOS rechazó el pedido sin mostrar su aviso: queda activarlos en Ajustes del Sistema.
    private(set) var notificationRequestFailed = false
    /// Viene encendido: sin la app abierta no llegan avisos.
    var launchAtLogin = true

    @ObservationIgnored var onConnect: ((URL) -> Void)?
    @ObservationIgnored var onCancel: (() -> Void)?
    @ObservationIgnored private var watch: Task<Void, Never>?
    /// En el ensayo los avisos quedan como se pidieron, sin leer los de verdad.
    @ObservationIgnored private let fixedNotifications: Bool

    /// `step`, `phase` y `notificationAccess` dejan la bienvenida ahí sin buscar nada (para el ensayo).
    init(mode: Mode, step: Step = .searching, phase: Phase? = nil, notificationAccess: NotificationAccess? = nil) {
        self.mode = mode
        self.step = step
        self.phase = phase ?? (mode == .firstRun ? .intro : .connect)
        self.notificationAccess = notificationAccess
        fixedNotifications = notificationAccess != nil
    }

    func go(to phase: Phase) {
        movingForward = phase > self.phase
        self.phase = phase
    }

    func start() {
        Task { await detect() }
    }

    func detect() async {
        step = .searching
        switch await PaperclipLocator.detect() {
        case let .running(local, health): step = .found(local, health)
        case let .stopped(local): step = .stopped(local)
        case .notInstalled: step = .notFound
        }
    }

    func searchAgain() {
        stopWatching()
        Task { await detect() }
    }

    func startPaperclip(_ local: LocalPaperclip) {
        starting = true
        startError = nil
        Task {
            if let error = await PaperclipLocator.start(local) {
                startError = error
                starting = false
            } else {
                watchUntilRunning()
            }
        }
    }

    func showAddress() {
        stopWatching()
        addressError = nil
        step = .address
    }

    func showInstall() {
        step = .install
        Task { await checkNode() }
    }

    func checkNode() async {
        node = .checking
        guard let version = await PaperclipLocator.nodeVersion() else {
            node = .missing
            return
        }
        node = PaperclipLocator.meetsNodeRequirement(version) ? .ready(version.text) : .old(version.text)
    }

    func openInstaller() {
        PaperclipLocator.openInstaller()
        installerOpened = true
        watchUntilRunning()
    }

    func connectAddress() {
        guard let url = PaperclipLocator.serverURL(address) else {
            addressError = String(localized: "Enter an address, for example 192.168.1.20:3100.")
            return
        }
        checkingAddress = true
        addressError = nil
        Task {
            let result = await PaperclipLocator.probe(url)
            checkingAddress = false
            switch result {
            case .success: connect(url)
            case let .failure(error): addressError = error.message
            }
        }
    }

    /// La primera vez sigue a los avisos; al cambiar de Paperclip, conecta ya.
    func connect(_ url: URL) {
        stopWatching()
        guard mode == .firstRun else {
            onConnect?(url)
            return
        }
        chosenURL = url
        go(to: .notifications)
    }

    /// «Abrir Paperclip», al final de la primera vez.
    func finish() {
        guard let chosenURL else { return }
        if launchAtLogin, LoginItem.status != .enabled { try? LoginItem.setEnabled(true) }
        onConnect?(chosenURL)
    }

    func refreshNotifications() async {
        guard !fixedNotifications else { return }
        notificationAccess = await NotificationAccess.current()
    }

    /// macOS muestra su aviso de permiso; si ya se negó, no vuelve a preguntar (queda Ajustes del Sistema).
    func requestNotifications() async {
        requestingNotifications = true
        let (access, failed) = await NotificationAccess.request()
        notificationAccess = access
        notificationRequestFailed = failed && access.permission == .notDetermined
        requestingNotifications = false
    }

    func cancel() {
        stopWatching()
        onCancel?()
    }

    /// Después de encender o instalar: vuelve a buscar hasta que Paperclip responda.
    private func watchUntilRunning() {
        stopWatching()
        watch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.watchInterval)
                guard !Task.isCancelled, let self else { return }
                if case let .running(local, health) = await PaperclipLocator.detect() {
                    starting = false
                    step = .found(local, health)
                    return
                }
            }
        }
    }

    private func stopWatching() {
        watch?.cancel()
        watch = nil
    }
}

/// Medidas de la bienvenida.
enum WelcomeDesign {
    static let windowSize = CGSize(width: 640, height: 580)
    /// El ícono grande del primer paso y el chico de los otros.
    static let iconSize: CGFloat = 104
    static let smallIconSize: CGFloat = 64
    static let iconTop: CGFloat = 62
    static let smallIconTop: CGFloat = 58
    /// Aire a los lados del contenido y, para los botones de abajo, desde el borde.
    static let contentInset: CGFloat = 56
    static let footerInset: CGFloat = 28
    static let cardWidth: CGFloat = 500
    static let featuresWidth: CGFloat = 440
    /// Lo que se desliza el contenido al pasar de un paso a otro.
    static let phaseShift: CGFloat = 24
    static let animation: Animation = .smooth(duration: 0.4)
    static let glow = Color.indigo
}

struct WelcomeView: View {
    @Bindable var model: WelcomeModel
    @FocusState private var addressFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .top) {
            PaneGlow(color: WelcomeDesign.glow)
            VStack(spacing: 0) {
                phaseContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .id(model.phase)
                    .transition(phaseTransition)
                footer
            }
        }
        .frame(width: WelcomeDesign.windowSize.width, height: WelcomeDesign.windowSize.height)
        .animation(WelcomeDesign.animation, value: model.phase)
    }

    @ViewBuilder private var phaseContent: some View {
        switch model.phase {
        case .intro: WelcomeIntroStep(appName: AppConfig.appName)
        case .connect: connectStep
        case .notifications: WelcomeNotificationsStep(model: model)
        }
    }

    /// Se desliza un poco hacia el lado al que se avanza; con «Reducir movimiento», solo se funde.
    private var phaseTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        let shift = model.movingForward ? WelcomeDesign.phaseShift : -WelcomeDesign.phaseShift
        return .asymmetric(
            insertion: .offset(x: shift).combined(with: .opacity),
            removal: .offset(x: -shift).combined(with: .opacity)
        )
    }

    private var connectStep: some View {
        VStack(spacing: 0) {
            header
            VStack(spacing: 12) {
                content
                links
            }
            .frame(maxWidth: WelcomeDesign.cardWidth)
            .padding(.top, 24)
            .id(stepKey)
            .transition(.blurReplace)
        }
        .padding(.horizontal, WelcomeDesign.contentInset)
        .animation(WelcomeDesign.animation, value: stepKey)
    }

    /// Cambia con el paso, no con lo de adentro: la animación es al pasar de uno a otro.
    private var stepKey: String {
        switch model.step {
        case .searching: "searching"
        case .found: "found"
        case .stopped: "stopped"
        case .notFound: "notFound"
        case .address: "address"
        case .install: "install"
        }
    }

    private var header: some View {
        VStack(spacing: 0) {
            AppIconImage(size: WelcomeDesign.smallIconSize)
                .padding(.top, WelcomeDesign.smallIconTop)
            Text(title)
                .font(.title)
                .bold()
                .padding(.top, 14)
            Text(subtitle)
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
        }
    }

    private var title: String {
        switch model.mode {
        case .firstRun: String(localized: "Connect your Paperclip")
        case .change: String(localized: "Switch Paperclip")
        }
    }

    private var subtitle: String {
        switch model.mode {
        case .firstRun:
            if case .found = model.step { return String(localized: "Dispatch opens the Paperclip you already use. I found this one on your Mac:") }
            return String(localized: "Dispatch opens the Paperclip you already use.")
        case let .change(current): return String(localized: "You’re using \(current.host() ?? current.absoluteString) now. Choose which one to connect to.")
        }
    }

    /// Debajo del recuadro: lo que no es el paso principal.
    @ViewBuilder private var links: some View {
        switch model.step {
        case .found, .stopped:
            Button("Use Another Address…", action: model.showAddress).buttonStyle(.link)
        case .notFound:
            HStack(spacing: 18) {
                Button("Search Again", action: model.searchAgain).buttonStyle(.link)
                if let url = PaperclipLocator.websiteURL {
                    Link("What is Paperclip?", destination: url)
                }
            }
            .font(.callout)
        case .searching, .address, .install:
            EmptyView()
        }
    }

    // MARK: Pasos

    @ViewBuilder private var content: some View {
        switch model.step {
        case .searching:
            Label {
                Text("Looking for Paperclip on this Mac…")
            } icon: {
                ProgressView().controlSize(.small)
            }
            .foregroundStyle(.secondary)
            .padding(.top, 12)
        case let .found(local, health):
            WelcomeCard {
                StatusLine(color: .green, title: String(localized: "Paperclip is running on this Mac")) {
                    AddressText(url: local.url)
                    Text(foundDetail(health)).foregroundStyle(.secondary)
                }
            }
        case let .stopped(local):
            WelcomeCard {
                StatusLine(color: .orange, title: String(localized: "Paperclip is installed, but not running")) {
                    AddressText(url: local.url)
                    Text(local.hasService
                        ? "It starts with its service, without opening anything."
                        : "It starts in a Terminal window, which has to stay open.")
                        .foregroundStyle(.secondary)
                    if model.starting {
                        Label {
                            Text("Starting… this may take a minute.")
                        } icon: {
                            ProgressView().controlSize(.mini)
                        }
                        .foregroundStyle(.secondary)
                    }
                }
            }
            if let error = model.startError {
                WarningRow(text: error).frame(maxWidth: .infinity, alignment: .leading)
            }
        case .notFound:
            VStack(spacing: 14) {
                Text("Couldn’t find Paperclip on this Mac.")
                    .font(.headline)
                WelcomeCard(spacing: 0) {
                    ChoiceRow(
                        title: String(localized: "Install it on this Mac"),
                        detail: String(localized: "It’s free and open source. It installs with its official command and needs Node.js.")
                    ) {
                        Button("Install…", action: model.showInstall).buttonStyle(.glass)
                    }
                    Divider().padding(.vertical, 12)
                    ChoiceRow(
                        title: String(localized: "Connect to one I already have"),
                        detail: String(localized: "On another computer on your network or over Tailscale.")
                    ) {
                        Button("Enter Address…", action: model.showAddress).buttonStyle(.glass)
                    }
                }
            }
        case .address:
            WelcomeCard {
                Text("Paperclip address").font(.headline)
                TextField("Address", text: $model.address, prompt: Text("http://192.168.1.20:3100"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .focused($addressFocused)
                    .onSubmit(model.connectAddress)
                    .defaultFocus($addressFocused, true)
                    .task {
                        // Al aparecer el campo todavía no está en la ventana: se enfoca en la vuelta siguiente.
                        await Task.yield()
                        addressFocused = true
                    }
                Text("The one you open in your browser to see Paperclip. If it asks you to sign in, you do that in the app’s window.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = model.addressError {
                WarningRow(text: error).frame(maxWidth: .infinity, alignment: .leading)
            }
        case .install:
            installContent
        }
    }

    @ViewBuilder private var installContent: some View {
        switch model.node {
        case .checking:
            Label {
                Text("Checking Node.js…")
            } icon: {
                ProgressView().controlSize(.small)
            }
            .foregroundStyle(.secondary)
            .padding(.top, 24)
        case .missing, .old:
            WelcomeCard {
                StatusLine(color: .orange, title: nodeTitle) {
                    Text("Paperclip runs on Node.js \(PaperclipLocator.minimumNode.major).\(PaperclipLocator.minimumNode.minor) or newer. Install it from its website and come back here.")
                        .foregroundStyle(.secondary)
                    HStack {
                        if let url = PaperclipLocator.nodeDownloadURL {
                            Button("Download Node.js") { NSWorkspace.shared.open(url) }
                                .buttonStyle(.glass)
                        }
                        Button("I’ve Installed It") { Task { await model.checkNode() } }
                            .buttonStyle(.glass)
                    }
                    .padding(.top, 4)
                }
            }
        case let .ready(version):
            WelcomeCard {
                Text(model.installerOpened ? "Installing in Terminal" : "It installs in Terminal").font(.headline)
                HStack(spacing: 6) {
                    Text(PaperclipLocator.installCommand)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                    CopyButton(text: PaperclipLocator.installCommand)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.fill.tertiary, in: .rect(cornerRadius: 6))
                Text("It’s the official command, with Node.js \(String(version.dropFirst())). It sets up local mode: only on this Mac and with no password. When it’s done, Paperclip keeps running in that window and this continues on its own.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if model.installerOpened {
                    Label {
                        Text("Waiting for Paperclip to start…")
                    } icon: {
                        ProgressView().controlSize(.mini)
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var nodeTitle: String {
        if case let .old(version) = model.node { return String(localized: "You have Node.js \(String(version.dropFirst())): a newer one is needed") }
        return String(localized: "Node.js is missing")
    }

    private func foundDetail(_ health: PaperclipHealth) -> String {
        let access = health.needsSignIn ? String(localized: "You’ll be asked to sign in.") : String(localized: "Local mode: you go straight in, no password.")
        return health.version.map { String(localized: "Version \($0). \(access)") } ?? access
    }

    // MARK: Botones

    /// A la izquierda lo de volver (o, en el primer paso, que no es oficial), al centro en qué paso va y a
    /// la derecha lo que sigue. A 28 puntos del borde, como en las apps de Apple.
    private var footer: some View {
        HStack(spacing: 10) {
            leadingItem
            Spacer(minLength: 0)
            if case .change = model.mode, model.step == .address || isInstalling {
                Button("Cancel", action: model.cancel)
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.glass)
                    .controlSize(.large)
            }
            primaryButton
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.glassProminent)
                .controlSize(.large)
        }
        .overlay {
            if model.mode == .firstRun {
                StepDots(current: model.phase.rawValue, count: 3)
            }
        }
        .padding(.horizontal, WelcomeDesign.footerInset)
        .padding(.bottom, WelcomeDesign.footerInset)
    }

    private var isInstalling: Bool {
        if case .install = model.step { return true }
        return false
    }

    @ViewBuilder private var leadingItem: some View {
        switch model.phase {
        case .intro:
            Text("Made for Paperclip · not an official app")
                .font(.caption)
                .foregroundStyle(.tertiary)
        case .notifications:
            Button("Back") { model.go(to: .connect) }.buttonStyle(.glass).controlSize(.large)
        case .connect:
            switch model.step {
            case .address, .install:
                Button("Back", action: model.searchAgain).buttonStyle(.glass).controlSize(.large)
            case .searching, .found, .stopped, .notFound:
                if model.mode == .firstRun {
                    Button("Back") { model.go(to: .intro) }.buttonStyle(.glass).controlSize(.large)
                } else {
                    Button("Cancel", action: model.cancel)
                        .keyboardShortcut(.cancelAction)
                        .buttonStyle(.glass)
                        .controlSize(.large)
                }
            }
        }
    }

    @ViewBuilder private var primaryButton: some View {
        switch model.phase {
        case .intro:
            Button("Get Started") { model.go(to: .connect) }
        case .notifications:
            Button("Open Paperclip", action: model.finish)
        case .connect:
            connectButton
        }
    }

    /// La primera vez el paso de conectar sigue a los avisos («Continuar»); al cambiar, conecta ya.
    @ViewBuilder private var connectButton: some View {
        let firstRun = model.mode == .firstRun
        switch model.step {
        case let .found(local, _):
            Button(firstRun ? "Continue" : "Open Paperclip") { model.connect(local.url) }
        case let .stopped(local):
            Button("Start Paperclip") { model.startPaperclip(local) }
                .disabled(model.starting)
        case .address:
            Button(action: model.connectAddress) {
                if model.checkingAddress {
                    ProgressView().controlSize(.small)
                } else {
                    Text(firstRun ? "Continue" : "Connect")
                }
            }
            .disabled(model.address.isEmpty || model.checkingAddress)
        case .install:
            if case .ready = model.node {
                Button(model.installerOpened ? "Open Terminal Again" : "Open Terminal", action: model.openInstaller)
            }
        case .searching, .notFound:
            EmptyView()
        }
    }
}

/// En qué paso va la primera vez: un punto por paso, el actual más largo y del color de acento.
private struct StepDots: View {
    let current: Int
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { index in
                Capsule()
                    .fill(index == current ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
                    .frame(width: index == current ? 20 : 7, height: 7)
            }
        }
        .animation(WelcomeDesign.animation, value: current)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(current + 1) of \(count)")
    }
}

// MARK: - Piezas

/// Un recuadro como las secciones de Ajustes.
struct WelcomeCard<Content: View>: View {
    var spacing: CGFloat = 8
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.fill.quinary, in: .rect(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(.separator.opacity(0.5)) }
    }
}

/// Un estado con su punto de color: encendido, apagado, falta algo.
private struct StatusLine<Detail: View>: View {
    let color: Color
    let title: String
    @ViewBuilder let detail: Detail

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Circle()
                .fill(color.gradient)
                .frame(width: 9, height: 9)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                detail
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Una opción con su explicación y su botón a la derecha.
private struct ChoiceRow<Action: View>: View {
    let title: String
    let detail: String
    @ViewBuilder let action: Action

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            action
        }
    }
}

private struct AddressText: View {
    let url: URL

    var body: some View {
        Text(url.absoluteString)
            .font(.callout.monospaced())
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
    }
}

// MARK: - Ventana

/// La ventana de la bienvenida: de tamaño fijo, sin título, el contenido llega hasta arriba.
@MainActor
final class WelcomeWindowController: NSWindowController, NSWindowDelegate {
    let model: WelcomeModel
    /// Se cerró con el botón rojo.
    var onClose: (() -> Void)?

    init(model: WelcomeModel) {
        self.model = model
        let hosting = NSHostingController(rootView: WelcomeView(model: model))
        hosting.sizingOptions = []
        let window = SnapshotableWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.title = String(localized: "Welcome")
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.setContentSize(WelcomeDesign.windowSize)
        super.init(window: window)
        window.delegate = self
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    func show() {
        showWindow(nil)
        NSApp.activate()
    }

    /// Cerrar sin el botón rojo (al conectar): no cuenta como cancelar.
    func dismiss() {
        window?.delegate = nil
        close()
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}
