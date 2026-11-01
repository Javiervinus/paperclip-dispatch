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
        .confirmationDialog("¿Quitar el bot?", isPresented: $confirmingRemoval) {
            Button("Quitar bot", role: .destructive, action: telegram.removeBot)
        } message: {
            Text("Se borra su token del llavero y deja de mandarte las decisiones. Para volver, hay que conectarlo de nuevo.")
        }
    }

    private var phase: Phase {
        if !telegram.hasToken { return .disconnected }
        return telegram.isPaired ? .connected : .pairing
    }

    private var botName: String {
        telegram.state.botUsername.map { "@\($0)" } ?? "tu bot"
    }

    // MARK: Conectar

    @ViewBuilder private var connectSection: some View {
        Section {
            LabeledContent {
                if let url = Self.botFatherURL {
                    Button("Abrir @BotFather") { NSWorkspace.shared.open(url) }
                        .buttonStyle(.glass)
                }
            } label: {
                StepLabel(number: 1, title: "Crea un bot con @BotFather", detail: "Escríbele /newbot y elige un nombre: te da un token.")
            }
            LabeledContent {
                HStack {
                    SecureField("Token", text: $token, prompt: Text("123456:ABC…"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(connect)
                    if working { ProgressView().controlSize(.small) }
                    Button("Conectar", action: connect)
                        .buttonStyle(.glassProminent)
                        .disabled(token.isEmpty || working)
                }
            } label: {
                StepLabel(number: 2, title: "Pega aquí su token", detail: nil)
            }
        } header: {
            Text("Conectar un bot")
        } footer: {
            Text("Las decisiones te llegan al teléfono con sus botones, para contestarlas desde ahí. El bot es solo tuyo y el token queda en el llavero de esta Mac, nunca en archivos. No hace falta una dirección pública: la app le pregunta a Telegram.")
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
                        Text("Vincula tu chat").font(.headline)
                        Text("Escanea el código con la cámara del teléfono y toca Iniciar en Telegram.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Abrir en esta Mac") { NSWorkspace.shared.open(url) }
                            .buttonStyle(.glass)
                        if let code = telegram.state.pairingCode {
                            HStack(spacing: 4) {
                                Text("O escríbele «/start \(code)»")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                CopyButton(text: "/start \(code)")
                            }
                        }
                        Label {
                            Text("Esperando…")
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
                if let chatName = telegram.state.chatName { Text("con \(chatName)") }
                Button("Quitar…", role: .destructive) { confirmingRemoval = true }
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
                Text("Mandar las decisiones a Telegram")
                Text("Cada una con sus botones; lo que tocas se aplica en Paperclip a tu nombre.")
            }
            botRow
            LabeledContent {
                Button(action: sendTest) {
                    if testSent {
                        Label("Enviado", systemImage: "checkmark")
                    } else {
                        Text("Mandar prueba")
                    }
                }
                .buttonStyle(.glass)
                .disabled(!telegram.state.enabled || working)
                .animation(SettingsDesign.animation, value: testSent)
            } label: {
                Text("Mensaje de prueba")
            }
        } footer: {
            Text("Para escribirle al agente de una decisión, respóndele a su mensaje: le llega como comentario en la tarea. Funciona mientras esta Mac y la app estén encendidas.")
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
                .accessibilityLabel("Paso \(number)")
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
    /// El borde blanco alrededor del avión, para separarlo de los módulos del QR.
    private static let badgeBorder: CGFloat = 3

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
                            .padding(Self.badgeBorder)
                            .background(
                                .white,
                                in: .rect(cornerRadius: (Self.badgeSide + 2 * Self.badgeBorder) * SettingsDesign.iconCornerRatio)
                            )
                    }
            }
        }
        .padding(8)
        .background(.white, in: .rect(cornerRadius: 12))
        .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
        .accessibilityLabel("Código QR del enlace al bot")
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
                Text("Explicar decisiones")
                Text("Agrega «💡 Explícamela» a cada decisión: te la cuenta en pocas líneas.")
            }
            if telegram.explainEnabled {
                Picker("Con", selection: engine) {
                    Text(automaticTitle).tag(Engine.automatic)
                    ForEach(cliOptions) { Text(title(for: $0)).tag($0) }
                    Divider()
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

    /// Lo justo para lo que está a la vista.
    private var footer: String {
        let base = "Lo cuenta un CLI de esta Mac, sin herramientas: solo lee la tarea y no decide ni escribe nada."
        guard telegram.explainEnabled else { return base }
        if telegram.engine == .custom {
            return base + " El comando recibe el texto por la entrada y responde por la salida."
        }
        return base + " «Automático» usa el CLI que más usan tus agentes, con su modelo por defecto y esfuerzo bajo."
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
