import AppKit
import SwiftUI

/// La bienvenida: encuentra el Paperclip de esta Mac o ayuda a encenderlo, instalarlo o escribir la
/// dirección de otro. Se abre la primera vez y desde Ajustes → Paperclip → Cambiar….
@MainActor
@Observable
final class WelcomeModel {
    enum Mode: Equatable {
        case firstRun
        case change(current: URL)
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
    var step: Step
    var address = ""
    var addressError: String?
    var checkingAddress = false
    var starting = false
    var startError: String?
    var node: NodeStatus = .checking
    var installerOpened = false

    @ObservationIgnored var onConnect: ((URL) -> Void)?
    @ObservationIgnored var onCancel: (() -> Void)?
    @ObservationIgnored private var watch: Task<Void, Never>?

    /// `step` deja la bienvenida en ese paso sin buscar nada (para el ensayo).
    init(mode: Mode, step: Step = .searching) {
        self.mode = mode
        self.step = step
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
            addressError = "Escribe una dirección, por ejemplo 192.168.1.20:3100."
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

    func connect(_ url: URL) {
        stopWatching()
        onConnect?(url)
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
    static let windowSize = CGSize(width: 600, height: 540)
    /// Lo que se veía del ícono del sistema a 96 puntos, sin su margen.
    static let iconSize: CGFloat = 78
    static let animation: Animation = .smooth(duration: 0.4)
    static let glow = Color.indigo
}

struct WelcomeView: View {
    @Bindable var model: WelcomeModel
    @FocusState private var addressFocused: Bool

    var body: some View {
        ZStack(alignment: .top) {
            PaneGlow(color: WelcomeDesign.glow)
            VStack(spacing: 0) {
                header
                VStack(spacing: 12) { content }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.top, 28)
                    .id(stepKey)
                    .transition(.blurReplace)
                footer
            }
            .padding(.horizontal, 44)
            .padding(.top, 52)
            .padding(.bottom, 24)
        }
        .frame(width: WelcomeDesign.windowSize.width, height: WelcomeDesign.windowSize.height)
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
        VStack(spacing: 10) {
            AppIconImage(size: WelcomeDesign.iconSize)
            Text(title)
                .font(.largeTitle)
                .bold()
            Text(subtitle)
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var title: String {
        switch model.mode {
        case .firstRun: "Te damos la bienvenida"
        case .change: "Cambiar de Paperclip"
        }
    }

    private var subtitle: String {
        switch model.mode {
        case .firstRun: "Tu Paperclip en una ventana de Mac, con avisos cuando una decisión espera por ti."
        case let .change(current): "Ahora usas \(current.host() ?? current.absoluteString). Elige a cuál conectarte."
        }
    }

    // MARK: Pasos

    @ViewBuilder private var content: some View {
        switch model.step {
        case .searching:
            Label {
                Text("Buscando Paperclip en esta Mac…")
            } icon: {
                ProgressView().controlSize(.small)
            }
            .foregroundStyle(.secondary)
            .padding(.top, 24)
        case let .found(local, health):
            WelcomeCard {
                StatusLine(color: .green, title: "Paperclip está encendido en esta Mac") {
                    AddressText(url: local.url)
                    Text(foundDetail(health)).foregroundStyle(.secondary)
                }
            }
        case let .stopped(local):
            WelcomeCard {
                StatusLine(color: .orange, title: "Paperclip está instalado, pero apagado") {
                    AddressText(url: local.url)
                    Text(local.hasService
                        ? "Se enciende con su servicio, sin abrir nada."
                        : "Se enciende en una ventana de la Terminal, que tiene que quedar abierta.")
                        .foregroundStyle(.secondary)
                    if model.starting {
                        Label {
                            Text("Encendiendo… puede tardar un minuto.")
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
                Text("No encontré Paperclip en esta Mac.")
                    .font(.headline)
                WelcomeCard(spacing: 0) {
                    ChoiceRow(
                        title: "Instalarlo en esta Mac",
                        detail: "Es gratis y de código abierto. Se instala con su comando oficial; necesita Node.js."
                    ) {
                        Button("Instalar…", action: model.showInstall).buttonStyle(.glass)
                    }
                    Divider().padding(.vertical, 12)
                    ChoiceRow(
                        title: "Conectarme a uno que ya tengo",
                        detail: "En otra computadora de tu red o por Tailscale."
                    ) {
                        Button("Escribir dirección…", action: model.showAddress).buttonStyle(.glass)
                    }
                }
                if let url = PaperclipLocator.websiteURL {
                    Link("¿Qué es Paperclip?", destination: url).font(.callout)
                }
            }
        case .address:
            WelcomeCard {
                Text("Dirección de Paperclip").font(.headline)
                TextField("Dirección", text: $model.address, prompt: Text("http://192.168.1.20:3100"))
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
                Text("La que abres en el navegador para ver Paperclip. Si pide iniciar sesión, lo haces en la ventana de la app.")
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
                Text("Revisando Node.js…")
            } icon: {
                ProgressView().controlSize(.small)
            }
            .foregroundStyle(.secondary)
            .padding(.top, 24)
        case .missing, .old:
            WelcomeCard {
                StatusLine(color: .orange, title: nodeTitle) {
                    Text("Paperclip corre sobre Node.js \(PaperclipLocator.minimumNode.major).\(PaperclipLocator.minimumNode.minor) o más nuevo. Instálalo desde su página y vuelve aquí.")
                        .foregroundStyle(.secondary)
                    HStack {
                        if let url = PaperclipLocator.nodeDownloadURL {
                            Button("Descargar Node.js") { NSWorkspace.shared.open(url) }
                                .buttonStyle(.glass)
                        }
                        Button("Ya lo instalé") { Task { await model.checkNode() } }
                            .buttonStyle(.glass)
                    }
                    .padding(.top, 4)
                }
            }
        case let .ready(version):
            WelcomeCard {
                Text(model.installerOpened ? "Instalando en la Terminal" : "Se instala en la Terminal").font(.headline)
                HStack(spacing: 6) {
                    Text(PaperclipLocator.installCommand)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                    CopyButton(text: PaperclipLocator.installCommand)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.fill.tertiary, in: .rect(cornerRadius: 6))
                Text("Es su comando oficial, con Node.js \(version.dropFirst()). Queda en modo local: solo en esta Mac y sin contraseña. Al terminar, Paperclip queda encendido en esa ventana y aquí se sigue solo.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if model.installerOpened {
                    Label {
                        Text("Esperando a que Paperclip arranque…")
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
        if case let .old(version) = model.node { return "Tienes Node.js \(version.dropFirst()): hace falta uno más nuevo" }
        return "Falta Node.js"
    }

    private func foundDetail(_ health: PaperclipHealth) -> String {
        let access = health.needsSignIn ? "Te va a pedir iniciar sesión." : "Modo local: entras directo, sin contraseña."
        return health.version.map { "Versión \($0). \(access)" } ?? access
    }

    // MARK: Botones

    private var footer: some View {
        HStack(spacing: 10) {
            secondaryButton
            Spacer()
            if case .change = model.mode {
                Button("Cancelar", action: model.cancel)
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.glass)
                    .controlSize(.large)
            }
            primaryButton
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.glassProminent)
                .controlSize(.large)
        }
    }

    @ViewBuilder private var secondaryButton: some View {
        switch model.step {
        case .found, .stopped:
            Button("Usar otra dirección…", action: model.showAddress).buttonStyle(.glass).controlSize(.large)
        case .notFound:
            Button("Buscar de nuevo", action: model.searchAgain).buttonStyle(.glass).controlSize(.large)
        case .address, .install:
            Button("Atrás", action: model.searchAgain).buttonStyle(.glass).controlSize(.large)
        case .searching:
            EmptyView()
        }
    }

    @ViewBuilder private var primaryButton: some View {
        switch model.step {
        case let .found(local, _):
            Button("Abrir Paperclip") { model.connect(local.url) }
        case let .stopped(local):
            Button("Encender Paperclip") { model.startPaperclip(local) }
                .disabled(model.starting)
        case .address:
            Button(action: model.connectAddress) {
                if model.checkingAddress {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Conectar")
                }
            }
            .disabled(model.address.isEmpty || model.checkingAddress)
        case .install:
            if case .ready = model.node {
                Button(model.installerOpened ? "Abrir la Terminal otra vez" : "Abrir la Terminal", action: model.openInstaller)
            }
        case .searching, .notFound:
            EmptyView()
        }
    }
}

// MARK: - Piezas

/// Un recuadro como las secciones de Ajustes.
private struct WelcomeCard<Content: View>: View {
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
        window.title = "Bienvenida"
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
        fatalError("init(coder:) no se usa")
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
