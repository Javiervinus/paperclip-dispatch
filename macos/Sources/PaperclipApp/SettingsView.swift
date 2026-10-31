import AppKit
import CoreImage.CIFilterBuiltins
import ServiceManagement
import SwiftUI

/// La ventana Ajustes (Cmd+,), con el aspecto de los ajustes de macOS.
@MainActor
final class SettingsWindowController: NSWindowController {
    init(preferences: Preferences, status: AppStatus, telegram: TelegramChannel, actions: SettingsView.Actions) {
        let hosting = NSHostingController(
            rootView: SettingsView(preferences: preferences, status: status, telegram: telegram, actions: actions)
        )
        hosting.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: hosting)
        window.title = "Ajustes"
        window.styleMask = [.titled, .closable]
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

struct SettingsView: View {
    struct Actions {
        let checkForUpdate: () -> Void
        let sendTestNotification: () -> Void
        let serverURL: URL
    }

    @Bindable var preferences: Preferences
    let status: AppStatus
    let telegram: TelegramChannel
    let actions: Actions

    @State private var loginItemStatus = SMAppService.mainApp.status
    @State private var loginItemError: String?

    var body: some View {
        Form {
            Section {
                Picker("Tema", selection: $preferences.appearance) {
                    ForEach(Preferences.Appearance.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Apariencia")
            } footer: {
                Text("«Sistema» sigue a la Mac, también cuando cambia sola por horario. Si eliges el tema en el menú de Paperclip, aquí se cambia igual.")
                    .settingsFootnote()
            }

            Section {
                Toggle("Avisar cuando llegue una decisión", isOn: $preferences.decisionNotifications)
                Toggle("Avisar también si estoy mirando Paperclip", isOn: $preferences.notifyWhileLooking)
                    .disabled(!preferences.decisionNotifications)
                Toggle("Número de pendientes en el ícono del Dock", isOn: $preferences.dockBadge)
                permissionRow
            } header: {
                Text("Avisos")
            } footer: {
                Text("Decisions incluye las preguntas y aprobaciones de los agentes, sus fallos y las alertas de presupuesto.")
                    .settingsFootnote()
            }

            TelegramSection(telegram: telegram)
            if telegram.hasToken, telegram.isPaired {
                ExplainSection(telegram: telegram)
            }

            Section {
                Toggle("Abrir al iniciar sesión", isOn: launchAtLogin)
                if loginItemStatus == .requiresApproval {
                    HStack {
                        Text("macOS pide aprobarlo en Ítems de inicio.")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Abrir Ajustes del Sistema") { SMAppService.openSystemSettingsLoginItems() }
                    }
                }
                if let loginItemError {
                    Text(loginItemError).foregroundStyle(.red)
                }
            } header: {
                Text("General")
            } footer: {
                Text("Los avisos llegan mientras la app esté abierta, aunque cierres la ventana (Cmd+W). Cmd+Q la cierra del todo.")
                    .settingsFootnote()
            }

            Section("Paperclip") {
                LabeledContent("Versión") {
                    HStack {
                        Text(versionText)
                        Button("Buscar actualización", action: actions.checkForUpdate)
                            .disabled(status.checkingUpdate)
                    }
                }
                LabeledContent("Dirección") {
                    Text(actions.serverURL.absoluteString).textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            loginItemStatus = SMAppService.mainApp.status
        }
    }

    @ViewBuilder private var permissionRow: some View {
        LabeledContent("Permiso de macOS") {
            HStack {
                switch status.notificationPermission {
                case "granted":
                    Label("Permitido", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Button("Probar", action: actions.sendTestNotification)
                case "denied":
                    Label("Bloqueado", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Button("Abrir Ajustes del Sistema", action: openNotificationSettings)
                default:
                    Text("Sin pedir todavía").foregroundStyle(.secondary)
                }
            }
        }
    }

    private var versionText: String {
        if status.checkingUpdate { return "Revisando…" }
        guard let current = status.paperclipVersion else {
            return status.updateCheckFailed ? "No pude revisar" : "Revisando…"
        }
        if let latest = status.latestVersion { return "\(current) · hay una nueva: \(latest)" }
        return "\(current) · al día"
    }

    private var launchAtLogin: Binding<Bool> {
        Binding {
            loginItemStatus == .enabled || loginItemStatus == .requiresApproval
        } set: { enabled in
            do {
                if enabled {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
                loginItemError = nil
            } catch {
                loginItemError = error.localizedDescription
            }
            loginItemStatus = SMAppService.mainApp.status
        }
    }

    private func openNotificationSettings() {
        let id = Bundle.main.bundleIdentifier ?? ""
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Telegram: el token del bot, vincular el chat con un enlace y, ya conectado, prender o apagar el envío.
private struct TelegramSection: View {
    let telegram: TelegramChannel

    @State private var token = ""
    @State private var working = false
    @State private var message: String?

    var body: some View {
        Section {
            if !telegram.hasToken {
                SecureField("Token del bot", text: $token, prompt: Text("123456:ABC…"))
                    .onSubmit(connect)
                HStack {
                    if working { ProgressView().controlSize(.small) }
                    Spacer()
                    Button("Conectar", action: connect)
                        .disabled(token.isEmpty || working)
                }
            } else if !telegram.isPaired {
                LabeledContent("Bot") { Text(botName) }
                if let url = telegram.pairingURL {
                    HStack(alignment: .top, spacing: 16) {
                        if let qr = Self.qrCode(url) {
                            Image(nsImage: qr)
                                .interpolation(.none)
                                .resizable()
                                .frame(width: 132, height: 132)
                                .accessibilityLabel("Código QR del enlace al bot")
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Falta vincular tu chat")
                            Text("Escanea el código con la cámara del teléfono y toca Iniciar en Telegram.")
                                .settingsFootnote()
                            Link("O ábrelo en esta Mac", destination: url)
                            Text("Si no abre, escríbele al bot «/start \(telegram.state.pairingCode ?? "")».")
                                .settingsFootnote()
                                .textSelection(.enabled)
                        }
                    }
                }
                HStack {
                    Spacer()
                    Button("Quitar bot", role: .destructive, action: telegram.removeBot)
                }
            } else {
                Toggle("Mandar las decisiones a Telegram", isOn: enabled)
                LabeledContent("Bot") {
                    Text(telegram.state.chatName.map { "\(botName) · con \($0)" } ?? botName)
                }
                HStack {
                    Spacer()
                    Button("Mandar prueba", action: sendTest)
                        .disabled(!telegram.state.enabled || working)
                    Button("Quitar bot", role: .destructive, action: telegram.removeBot)
                }
            }
            if let problem = message ?? telegram.problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("Telegram")
        } footer: {
            Text(footer).settingsFootnote()
        }
    }

    /// El enlace como QR, para abrir el bot desde el teléfono. CoreImage lo dibuja negro sobre blanco.
    private static func qrCode(_ url: URL) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.absoluteString.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)) else {
            return nil
        }
        let representation = NSCIImageRep(ciImage: output)
        let image = NSImage(size: representation.size)
        image.addRepresentation(representation)
        return image
    }

    private var botName: String {
        telegram.state.botUsername.map { "@\($0)" } ?? "Sin nombre"
    }

    private var footer: String {
        if telegram.hasToken {
            return "Contesta con los botones de cada decisión. Si respondes a una con texto, queda como comentario en su tarea y le llega al agente. Llegan mientras la Mac y esta app estén encendidas."
        }
        return "Crea un bot solo para esto con @BotFather (/newbot) y pega aquí su token. Queda en el llavero de la Mac."
    }

    private var enabled: Binding<Bool> {
        Binding { telegram.state.enabled } set: { telegram.setEnabled($0) }
    }

    private func connect() {
        guard !token.isEmpty, !working else { return }
        working = true
        message = nil
        Task {
            message = await telegram.connect(token: token)
            if message == nil { token = "" }
            working = false
        }
    }

    private func sendTest() {
        working = true
        message = nil
        Task {
            message = await telegram.sendTest()
            working = false
        }
    }
}

/// «Explicar decisiones»: el botón «Explícamela», con qué CLI y con qué modelo. Muestra lo que encontró en
/// la Mac: los CLIs instalados, el que elige «Automático» y los modelos que ofrece cada uno.
private struct ExplainSection: View {
    typealias Engine = DecisionExplainer.Engine

    let telegram: TelegramChannel

    @State private var detection: DecisionExplainer.Detection?
    @State private var models: [DecisionExplainer.Model] = []
    @State private var loadingModels = false
    @State private var command = ""

    var body: some View {
        Section {
            Toggle(isOn: enabled) {
                Text("Explicar decisiones")
                Text("Agrega «💡 Explícamela» a cada decisión: te la cuenta en pocas líneas.")
            }
            if telegram.explainEnabled {
                Picker("Con", selection: engine) {
                    Text(automaticTitle).tag(Engine.automatic)
                    ForEach(cliOptions) { Text(title(for: $0)).tag($0) }
                    Text(Engine.custom.title).tag(Engine.custom)
                }
                if telegram.engine == .custom {
                    TextField("Comando", text: $command, prompt: Text("p. ej. gemini -p"))
                        .onChange(of: command) { telegram.setCustomCommand(command) }
                } else if let effective {
                    Picker("Modelo", selection: model(for: effective)) {
                        Text("Automático").tag("")
                        ForEach(modelOptions(for: effective)) { Text($0.title).tag($0.id) }
                    }
                    .disabled(loadingModels)
                }
            }
        } footer: {
            Text(footer).settingsFootnote()
        }
        .task {
            command = telegram.customCommand
            detection = await telegram.detectExplainers()
        }
        .task(id: effective) {
            guard let effective else { return }
            loadingModels = true
            models = await telegram.explainerModels(for: effective)
            loadingModels = false
        }
    }

    /// El CLI que se usa de verdad: el elegido o, en «Automático», el detectado.
    private var effective: Engine? {
        switch telegram.engine {
        case .automatic: detection?.automatic
        case .custom: nil
        default: telegram.engine
        }
    }

    private var automaticTitle: String {
        guard let detection else { return "Automático (buscando…)" }
        return detection.automatic.map { "Automático · \($0.title)" } ?? "Automático (no encontré ninguno)"
    }

    /// Los instalados; el elegido aparece aunque ya no esté, para que se vea qué pasó.
    private var cliOptions: [Engine] {
        var options = detection?.installed ?? []
        if Engine.clis.contains(telegram.engine), !options.contains(telegram.engine) { options.append(telegram.engine) }
        return options
    }

    private func title(for engine: Engine) -> String {
        guard let detection, !detection.installed.contains(engine) else { return engine.title }
        return "\(engine.title) (no instalado)"
    }

    /// Los del CLI, más el guardado si el CLI ya no lo ofrece.
    private func modelOptions(for engine: Engine) -> [DecisionExplainer.Model] {
        let saved = telegram.model(for: engine)
        guard !saved.isEmpty, !models.contains(where: { $0.id == saved }) else { return models }
        return models + [DecisionExplainer.Model(id: saved, title: saved)]
    }

    private var footer: String {
        "Te la explica un CLI de esta Mac sin herramientas: solo lee la tarea, lo que anotó el agente y los " +
            "últimos comentarios, y no decide ni escribe nada. Para preguntar algo, respóndele a la decisión y " +
            "le llega al agente. «Automático» usa el CLI que más usan tus agentes de Paperclip; en el modelo, " +
            "el que el CLI tenga por defecto, con esfuerzo bajo. «Otro comando…» sirve para cualquier otro " +
            "CLI: recibe el texto por la entrada y responde por la salida."
    }

    private var enabled: Binding<Bool> {
        Binding { telegram.explainEnabled } set: { telegram.setExplainEnabled($0) }
    }

    private var engine: Binding<Engine> {
        Binding { telegram.engine } set: { telegram.setEngine($0) }
    }

    private func model(for engine: Engine) -> Binding<String> {
        Binding { telegram.model(for: engine) } set: { telegram.setModel($0, for: engine) }
    }
}

private extension View {
    func settingsFootnote() -> some View {
        font(.footnote).foregroundStyle(.secondary)
    }
}
