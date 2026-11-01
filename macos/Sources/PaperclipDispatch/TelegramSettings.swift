import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI

/// Telegram en Ajustes: conectar el bot, vincular el chat y, ya conectado, el envío, la prueba y
/// «Explicar decisiones». Cada paso reemplaza al anterior con una animación.
struct TelegramPane: View {
    private enum Phase {
        case disconnected, pairing, connected
    }

    private static let botFatherURL = URL(string: "https://t.me/BotFather")

    let telegram: TelegramChannel

    @State private var token = ""
    @State private var working = false
    @State private var message: String?
    @State private var testSent = false
    @State private var confirmingRemoval = false

    var body: some View {
        SettingsForm {
            switch phase {
            case .disconnected: connectSection
            case .pairing: pairingSection
            case .connected:
                connectedSection
                ExplainSection(telegram: telegram)
            }
            if let problem = message ?? telegram.problem {
                Section { WarningRow(text: problem) }
            }
        }
        .animation(SettingsDesign.animation, value: phase)
        .confirmationDialog("Remove the bot?", isPresented: $confirmingRemoval) {
            Button("Remove Bot", role: .destructive, action: telegram.removeBot)
        } message: {
            Text("Its token is deleted from the Keychain and it stops sending you decisions. To use it again, you’ll have to connect it again.")
        }
    }

    private var phase: Phase {
        if !telegram.hasToken { return .disconnected }
        return telegram.isPaired ? .connected : .pairing
    }

    private var botName: String {
        telegram.state.botUsername.map { "@\($0)" } ?? String(localized: "your bot")
    }

    // MARK: Conectar

    @ViewBuilder private var connectSection: some View {
        Section {
            LabeledContent {
                if let url = Self.botFatherURL {
                    Button("Open @BotFather") { NSWorkspace.shared.open(url) }
                        .buttonStyle(.glass)
                }
            } label: {
                StepLabel(number: 1, title: String(localized: "Create a bot with @BotFather"), detail: String(localized: "Send it /newbot and choose a name: it gives you a token."))
            }
            LabeledContent {
                HStack {
                    SecureField("Token", text: $token, prompt: Text("123456:ABC…"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(connect)
                    if working { ProgressView().controlSize(.small) }
                    Button("Connect", action: connect)
                        .buttonStyle(.glassProminent)
                        .disabled(token.isEmpty || working)
                }
            } label: {
                StepLabel(number: 2, title: String(localized: "Paste its token here"), detail: nil)
            }
        } header: {
            Text("Connect a bot")
        } footer: {
            Text("Decisions reach your phone with their buttons, so you can answer them from there. The bot is yours alone, and its token stays in this Mac’s Keychain, never in files. No public address needed: the app asks Telegram.")
                .settingsFootnote()
        }
    }

    // MARK: Vincular

    @ViewBuilder private var pairingSection: some View {
        if let url = telegram.pairingURL {
            Section {
                HStack(spacing: 20) {
                    PairingCode(url: url)
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Connect your chat").font(.headline)
                        Text("Scan the code with your phone’s camera and tap Start in Telegram.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Open on This Mac") { NSWorkspace.shared.open(url) }
                            .buttonStyle(.glass)
                        if let code = telegram.state.pairingCode {
                            HStack(spacing: 4) {
                                Text("Or send it “/start \(code)”")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                CopyButton(text: "/start \(code)")
                            }
                        }
                        Label {
                            Text("Waiting…")
                        } icon: {
                            ProgressView().controlSize(.mini)
                        }
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 6)
                botRow
            }
        }
    }

    /// El bot y cómo quitarlo (pide confirmación).
    private var botRow: some View {
        LabeledContent {
            HStack(spacing: 10) {
                if let chatName = telegram.state.chatName { Text("with \(chatName)") }
                Button("Remove…", role: .destructive) { confirmingRemoval = true }
                    .buttonStyle(.glass)
            }
        } label: {
            Text("Bot")
            Text(botName)
        }
    }

    // MARK: Conectado

    @ViewBuilder private var connectedSection: some View {
        Section {
            Toggle(isOn: enabled) {
                Text("Send decisions to Telegram")
                Text("Each one comes with its buttons; whatever you tap is applied in Paperclip on your behalf.")
            }
            botRow
            LabeledContent {
                Button(action: sendTest) {
                    if testSent {
                        Label("Sent", systemImage: "checkmark")
                    } else {
                        Text("Send Test")
                    }
                }
                .buttonStyle(.glass)
                .disabled(!telegram.state.enabled || working)
                .animation(SettingsDesign.animation, value: testSent)
            } label: {
                Text("Test message")
            }
        } footer: {
            Text("To write to a decision’s agent, reply to its message: it arrives as a comment on the task. Works while this Mac and the app are on.")
                .settingsFootnote()
        }
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
            guard message == nil else { return }
            testSent = true
            try? await Task.sleep(for: SettingsDesign.feedbackDuration)
            testSent = false
        }
    }
}

/// Un paso numerado, con el número en un círculo del color de Telegram y el texto alineado a su derecha.
private struct StepLabel: View {
    let number: Int
    let title: String
    let detail: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "\(number).circle.fill")
                .foregroundStyle(SettingsDesign.telegramBlue)
                .accessibilityLabel("Step \(number)")
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail {
                    Text(detail).font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// El enlace al bot como QR, con el avión de Telegram al centro. Va con corrección alta para que el avión
/// no le quite lectura.
private struct PairingCode: View {
    private static let side: CGFloat = 136
    private static let badgeSide: CGFloat = 30

    let url: URL

    var body: some View {
        Group {
            if let image = Self.qrCode(url) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: Self.side, height: Self.side)
                    .overlay {
                        RoundedRectangle(cornerRadius: Self.badgeSide * SettingsDesign.iconCornerRatio)
                            .fill(SettingsDesign.telegramBlue.gradient)
                            .frame(width: Self.badgeSide, height: Self.badgeSide)
                            .overlay {
                                Image(systemName: "paperplane.fill")
                                    .font(.callout)
                                    .foregroundStyle(.white)
                            }
                            .padding(3)
                            .background(.white, in: .rect(cornerRadius: (Self.badgeSide + 6) * SettingsDesign.iconCornerRatio))
                    }
            }
        }
        .padding(8)
        .background(.white, in: .rect(cornerRadius: 12))
        .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
        .accessibilityLabel("QR code for the bot link")
    }

    /// CoreImage lo dibuja negro sobre blanco, un punto por módulo; se agranda sin suavizar.
    private static func qrCode(_ url: URL) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.absoluteString.utf8)
        filter.correctionLevel = "H"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)) else {
            return nil
        }
        let representation = NSCIImageRep(ciImage: output)
        let image = NSImage(size: representation.size)
        image.addRepresentation(representation)
        return image
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
                Text("Explain decisions")
                Text("Adds “💡 Explain it to me” to each decision: it explains it in a few lines.")
            }
            if telegram.explainEnabled {
                Picker("Using", selection: engine) {
                    Text(automaticTitle).tag(Engine.automatic)
                    ForEach(cliOptions) { Text(title(for: $0)).tag($0) }
                    Divider()
                    Text(Engine.custom.title).tag(Engine.custom)
                }
                if telegram.engine == .custom {
                    TextField("Command", text: $command, prompt: Text("e.g. gemini -p"))
                        .onChange(of: command) { telegram.setCustomCommand(command) }
                } else if let effective {
                    Picker("Model", selection: model(for: effective)) {
                        Text("Automatic").tag("")
                        ForEach(modelOptions(for: effective)) { Text($0.title).tag($0.id) }
                    }
                    .disabled(loadingModels)
                }
            }
        } footer: {
            Text(footer).settingsFootnote()
        }
        .animation(SettingsDesign.animation, value: telegram.explainEnabled)
        .animation(SettingsDesign.animation, value: telegram.engine)
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
        guard let detection else { return String(localized: "Automatic (searching…)") }
        return detection.automatic.map { String(localized: "Automatic · \($0.title)") } ?? String(localized: "Automatic (none found)")
    }

    /// Los instalados; el elegido aparece aunque ya no esté, para que se vea qué pasó.
    private var cliOptions: [Engine] {
        var options = detection?.installed ?? []
        if Engine.clis.contains(telegram.engine), !options.contains(telegram.engine) { options.append(telegram.engine) }
        return options
    }

    private func title(for engine: Engine) -> String {
        guard let detection, !detection.installed.contains(engine) else { return engine.title }
        return String(localized: "\(engine.title) (not installed)")
    }

    /// Los del CLI, más el guardado si el CLI ya no lo ofrece.
    private func modelOptions(for engine: Engine) -> [DecisionExplainer.Model] {
        let saved = telegram.model(for: engine)
        guard !saved.isEmpty, !models.contains(where: { $0.id == saved }) else { return models }
        return models + [DecisionExplainer.Model(id: saved, title: saved)]
    }

    /// Lo justo para lo que está a la vista.
    private var footer: String {
        let base = String(localized: "A CLI on this Mac explains it, with no tools: it only reads the task and never decides or writes anything.")
        guard telegram.explainEnabled else { return base }
        if telegram.engine == .custom {
            return base + " " + String(localized: "The command receives the text on standard input and replies on standard output.")
        }
        return base + " " + String(localized: "“Automatic” uses the CLI your agents use most, with its default model and low effort.")
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
