import AppKit
import ServiceManagement
import SwiftUI

/// Medidas, colores y tiempos de Ajustes, para que todas las pestañas se vean iguales.
enum SettingsDesign {
    /// Fija, como Ajustes del Sistema: lo que no cabe se desplaza por debajo de la barra.
    static let windowSize = CGSize(width: 580, height: 620)
    static let glowHeight: CGFloat = 340
    static let iconSize: CGFloat = 54
    /// El ícono de la app trae un margen transparente (el dibujo ocupa 824 de 1024 px): se dibuja más grande
    /// y ocupa lo de `iconSize`, para que quede alineado con el texto de las filas.
    static let appIconSize: CGFloat = iconSize * 1024 / 824
    /// Aire entre el selector de la barra y lo primero de cada pestaña.
    static let contentTopSpacing: CGFloat = 16
    /// El redondeo de los íconos de macOS: un 22,5 % del lado.
    static let iconCornerRatio: CGFloat = 0.225
    static let thumbnailSize = CGSize(width: 88, height: 58)
    static let paneAnimation: Animation = .smooth(duration: 0.4)
    static let animation: Animation = .smooth(duration: 0.3)
    /// Lo que dura un «Enviado» o un «Copiado» antes de volver a su texto.
    static let feedbackDuration: Duration = .seconds(2)
    static let telegramBlue = Color(red: 0.16, green: 0.63, blue: 0.92)
}

/// Una pestaña de Ajustes. Es un solo tipo para que la ventana arme todas igual.
struct SettingsPaneView: View {
    let pane: SettingsPane
    let preferences: Preferences
    let status: AppStatus
    let telegram: TelegramChannel
    let actions: SettingsActions

    var body: some View {
        switch pane {
        case .general: GeneralPane(preferences: preferences)
        case .notifications: NotificationsPane(preferences: preferences, status: status, actions: actions)
        case .telegram: TelegramPane(telegram: telegram)
        case .paperclip: PaperclipPane(status: status, actions: actions)
        }
    }
}

// MARK: - General

private struct GeneralPane: View {
    @Bindable var preferences: Preferences

    @State private var loginItemStatus = SMAppService.mainApp.status
    @State private var loginItemError: String?

    var body: some View {
        SettingsForm {
            Section {
                AppearancePicker(selection: $preferences.appearance)
            } header: {
                Text("Apariencia")
            } footer: {
                Text("«Sistema» sigue a la Mac, también cuando cambia sola por horario. Si eliges el tema en el menú de Paperclip, aquí cambia igual.")
                    .settingsFootnote()
            }
            Section {
                Toggle(isOn: launchAtLogin) {
                    Text("Abrir al iniciar sesión")
                    Text("Así los avisos llegan desde que prendes la Mac.")
                }
                if loginItemStatus == .requiresApproval {
                    LabeledContent("macOS pide aprobarla en Ítems de inicio.") {
                        Button("Abrir Ajustes del Sistema") { SMAppService.openSystemSettingsLoginItems() }
                            .buttonStyle(.glass)
                    }
                }
                if let loginItemError {
                    WarningRow(text: loginItemError)
                }
            } footer: {
                Text("Cerrar la ventana (Cmd+W) no apaga los avisos: la app sigue revisando. Cmd+Q la cierra del todo.")
                    .settingsFootnote()
            }
            Section {
                Toggle(isOn: $preferences.liquidGlassPage) {
                    Text("Liquid Glass en Paperclip")
                    Text("La barra lateral de Paperclip sobre vidrio, como en las apps de macOS 26.")
                }
            } header: {
                Text("Experimental")
            } footer: {
                Text("Retoca la página de Paperclip por dentro: una versión nueva de Paperclip lo puede descuadrar. Apagado, Paperclip se ve tal cual.")
                    .settingsFootnote()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            loginItemStatus = SMAppService.mainApp.status
        }
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
}

/// El tema con miniaturas, como en Ajustes del Sistema → Apariencia.
private struct AppearancePicker: View {
    @Binding var selection: Preferences.Appearance

    var body: some View {
        HStack(spacing: 28) {
            ForEach(Preferences.Appearance.allCases) { appearance in
                let selected = selection == appearance
                Button {
                    withAnimation(SettingsDesign.animation) { selection = appearance }
                } label: {
                    VStack(spacing: 8) {
                        AppearanceThumbnail(appearance: appearance)
                            .frame(width: SettingsDesign.thumbnailSize.width, height: SettingsDesign.thumbnailSize.height)
                            .clipShape(.rect(cornerRadius: 7))
                            .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(.separator) }
                            .padding(3)
                            .overlay {
                                RoundedRectangle(cornerRadius: 10)
                                    .strokeBorder(Color.accentColor, lineWidth: 3)
                                    .opacity(selected ? 1 : 0)
                            }
                            .scaleEffect(selected ? 1 : 0.96)
                        Text(appearance.title)
                            .font(.callout)
                            .foregroundStyle(selected ? .primary : .secondary)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(appearance.title)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
    }
}

/// Una ventana chica sobre un fondo de pantalla; «Sistema», mitad clara y mitad oscura.
private struct AppearanceThumbnail: View {
    let appearance: Preferences.Appearance

    var body: some View {
        switch appearance {
        case .light: WindowSketch(dark: false)
        case .dark: WindowSketch(dark: true)
        case .system: WindowSketch(dark: false).overlay { WindowSketch(dark: true).mask { DiagonalHalf() } }
        }
    }
}

private struct WindowSketch: View {
    private static let lightWallpaper = [Color(red: 0.55, green: 0.74, blue: 0.98), Color(red: 0.86, green: 0.78, blue: 0.97)]
    private static let darkWallpaper = [Color(red: 0.10, green: 0.12, blue: 0.27), Color(red: 0.29, green: 0.17, blue: 0.40)]

    let dark: Bool

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack(alignment: .topLeading) {
                LinearGradient(
                    colors: dark ? Self.darkWallpaper : Self.lightWallpaper,
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                HStack(alignment: .top, spacing: size.width * 0.04) {
                    RoundedRectangle(cornerRadius: 2.5)
                        .fill(dark ? Color(white: 0.26) : Color(white: 0.9))
                        .frame(width: size.width * 0.2)
                    VStack(alignment: .leading, spacing: size.height * 0.07) {
                        Capsule().fill(Color.accentColor).frame(width: size.width * 0.22)
                        Capsule().fill(dark ? Color(white: 0.34) : Color(white: 0.84))
                        Capsule().fill(dark ? Color(white: 0.34) : Color(white: 0.84)).frame(width: size.width * 0.3)
                    }
                    .frame(height: size.height * 0.3)
                    .padding(.top, size.height * 0.06)
                }
                .padding(size.width * 0.025)
                .frame(width: size.width * 0.8, height: size.height * 0.68, alignment: .topLeading)
                .background(dark ? Color(white: 0.15) : .white, in: .rect(cornerRadius: 4))
                .shadow(color: .black.opacity(0.25), radius: 1.5, y: 0.5)
                .offset(x: size.width * 0.1, y: size.height * 0.18)
            }
        }
    }
}

private struct DiagonalHalf: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.closeSubpath()
        }
    }
}

// MARK: - Avisos

private struct NotificationsPane: View {
    @Bindable var preferences: Preferences
    let status: AppStatus
    let actions: SettingsActions

    @State private var testSent = false

    var body: some View {
        SettingsForm {
            Section {
                LabeledContent {
                    if status.notificationPermission == "denied" {
                        Button("Abrir Ajustes del Sistema", action: openNotificationSettings)
                            .buttonStyle(.glass)
                    } else {
                        permissionBadge
                    }
                } label: {
                    Text("Permiso de macOS")
                    Text(permissionDetail)
                }
            }
            .animation(SettingsDesign.animation, value: status.notificationPermission)
            Section {
                Toggle(isOn: $preferences.decisionNotifications) {
                    Text("Avisar cuando llegue una decisión")
                    Text("Preguntas y aprobaciones de los agentes, sus fallos y las alertas de presupuesto.")
                }
                Toggle(isOn: $preferences.notifyWhileLooking) {
                    Text("Avisar también si estoy mirando Paperclip")
                    Text("Con la ventana al frente, la barra lateral ya las muestra.")
                }
                .disabled(!preferences.decisionNotifications)
                Toggle(isOn: $preferences.dockBadge) {
                    Text("Número de pendientes en el Dock")
                    Text("Todo lo que espera en Decisions, no solo lo de hoy.")
                }
            }
            Section {
                LabeledContent {
                    Button(action: sendTest) {
                        if testSent {
                            Label("Enviado", systemImage: "checkmark")
                        } else {
                            Text("Probar")
                        }
                    }
                    .buttonStyle(.glass)
                    .disabled(status.notificationPermission == "denied")
                    .animation(SettingsDesign.animation, value: testSent)
                } label: {
                    Text("Aviso de prueba")
                    Text("Para ver cómo se ve y si macOS lo deja pasar.")
                }
            } footer: {
                Text("Con No molestar o un modo de concentración, los avisos no aparecen en pantalla: quedan en el Centro de notificaciones.")
                    .settingsFootnote()
            }
        }
    }

    @ViewBuilder private var permissionBadge: some View {
        switch status.notificationPermission {
        case "granted": StatusBadge(text: "Permitidos", symbol: "checkmark.circle.fill", tint: .green)
        default: StatusBadge(text: "Sin pedir", symbol: "questionmark.circle.fill", tint: .secondary)
        }
    }

    private var permissionDetail: String {
        switch status.notificationPermission {
        case "granted": "Te avisa cuando una decisión espera por ti, aunque estés en otra app."
        case "denied": "macOS tiene bloqueados los avisos de esta app."
        default: "La app lo pide al abrirse; sin él no puede avisarte."
        }
    }

    private func sendTest() {
        actions.sendTestNotification()
        testSent = true
        Task {
            try? await Task.sleep(for: SettingsDesign.feedbackDuration)
            testSent = false
        }
    }

    private func openNotificationSettings() {
        let id = Bundle.main.bundleIdentifier ?? ""
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Paperclip

private struct PaperclipPane: View {
    let status: AppStatus
    let actions: SettingsActions

    var body: some View {
        SettingsForm {
            Section {} header: {
                PaneHero(title: "Paperclip", subtitle: versionLine) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: SettingsDesign.appIconSize, height: SettingsDesign.appIconSize)
                        .frame(width: SettingsDesign.iconSize, height: SettingsDesign.iconSize)
                        .accessibilityHidden(true)
                } accessory: {
                    updateAccessory
                }
            }
            Section {
                LabeledContent {
                    HStack(spacing: 6) {
                        CopyButton(text: actions.serverURL.absoluteString)
                        Button("Cambiar…", action: actions.changeServer)
                            .buttonStyle(.glass)
                    }
                } label: {
                    Text("Dirección")
                    Text(actions.serverURL.absoluteString)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                if let reason = status.updatesUnavailable {
                    LabeledContent {
                        if actions.isLocalServer {
                            CopyButton(text: UpdateController.installCLICommand)
                        }
                    } label: {
                        Text("Versiones nuevas")
                        Text(actions.isLocalServer
                            ? "\(reason) Se instala con \(UpdateController.installCLICommand) y se ve al volver a abrir la app."
                            : reason)
                    }
                } else {
                    LabeledContent {
                        Button(action: actions.checkForUpdate) {
                            if status.checkingUpdate {
                                ProgressView().controlSize(.small)
                            } else {
                                Text("Buscar ahora")
                            }
                        }
                        .buttonStyle(.glass)
                        .disabled(status.checkingUpdate || status.updateProgress != nil)
                    } label: {
                        Text("Versiones nuevas")
                        Text(checkLine)
                            .contentTransition(.opacity)
                            .animation(SettingsDesign.animation, value: checkLine)
                    }
                    if let error = status.updateCheckError {
                        WarningRow(text: error)
                    }
                }
            } footer: {
                if status.updatesUnavailable == nil {
                    Text("Paperclip nunca se actualiza solo: reiniciarlo corta lo que estén haciendo los agentes, así que tú eliges cuándo.")
                        .settingsFootnote()
                }
            }
            Section {} footer: {
                Text("\(AppConfig.appName) \(Self.appVersion)")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var versionLine: String {
        if status.updatesUnavailable != nil {
            return actions.isLocalServer ? "Instalado en esta Mac." : "En \(actions.serverURL.host() ?? "otra computadora")."
        }
        guard let current = status.paperclipVersion else {
            return status.updateCheckError != nil ? "No pude leer la versión instalada." : "Revisando la versión…"
        }
        if let latest = status.latestVersion { return "Tienes la \(current). Salió la \(latest)." }
        return "Versión \(current), la última estable."
    }

    /// Cuándo se revisó, para que «Buscar ahora» muestre su resultado aquí mismo.
    private var checkLine: String {
        let every = "cada \(Int(UpdateController.checkInterval / 3600)) horas"
        guard let checked = status.lastCheckedAt else { return "Se revisa sola \(every)." }
        return "Revisado a las \(checked.formatted(date: .omitted, time: .shortened)); se revisa sola \(every)."
    }

    @ViewBuilder private var updateAccessory: some View {
        if let progress = status.updateProgress {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(progress).font(.callout).foregroundStyle(.secondary)
            }
        } else if status.checkingUpdate {
            StatusBadge(text: "Revisando…", symbol: "arrow.clockwise", tint: .secondary)
        } else if let latest = status.latestVersion {
            Button("Actualizar a \(latest)", action: actions.installUpdate)
                .buttonStyle(.glassProminent)
                .controlSize(.large)
        } else if status.paperclipVersion != nil {
            StatusBadge(text: "Al día", symbol: "checkmark.circle.fill", tint: .green, bounce: status.lastCheckedAt)
        } else if status.updateCheckError != nil {
            StatusBadge(text: "Sin revisar", symbol: "exclamationmark.triangle.fill", tint: .orange)
        }
    }

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }
}

// MARK: - Piezas comunes

/// El formulario de una pestaña: sin fondo propio, para que se vea el color de la pestaña, y desplazable
/// por debajo de la barra.
struct SettingsForm<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        Form { content }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .contentMargins(.top, SettingsDesign.contentTopSpacing, for: .scrollContent)
    }
}

/// Arriba de la pestaña Paperclip, como en Ajustes del Sistema: el ícono de la app a la izquierda, alineado
/// con el texto de las filas de abajo, la versión a su lado y el estado a la derecha. Las otras pestañas no
/// llevan: repetirían el nombre que ya dice el selector.
struct PaneHero<Icon: View, Accessory: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let icon: Icon
    @ViewBuilder let accessory: Accessory

    var body: some View {
        HStack(spacing: 14) {
            icon
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.title2)
                    .bold()
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.opacity)
            }
            Spacer(minLength: 12)
            accessory
        }
        .padding(.bottom, 14)
        .textCase(nil)
        .animation(SettingsDesign.animation, value: subtitle)
    }
}

/// Un estado corto en una cápsula de vidrio teñida: «Conectado», «Al día».
struct StatusBadge<Trigger: Equatable>: View {
    let text: String
    let symbol: String
    let tint: Color
    var bounce: Trigger

    var body: some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: symbol).symbolEffect(.bounce, value: bounce)
        }
        .font(.callout)
        .foregroundStyle(tint)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .glassEffect(.regular.tint(tint.opacity(0.16)), in: .capsule)
        .fixedSize()
        .transition(.opacity.combined(with: .scale(scale: 0.9)))
    }
}

extension StatusBadge where Trigger == Int {
    init(text: String, symbol: String, tint: Color) {
        self.init(text: text, symbol: symbol, tint: tint, bounce: 0)
    }
}

struct WarningRow: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Copia un texto y lo confirma con una palomita por un momento.
struct CopyButton: View {
    let text: String

    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            Task {
                try? await Task.sleep(for: SettingsDesign.feedbackDuration)
                copied = false
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 16)
        }
        .buttonStyle(.borderless)
        .help(copied ? "Copiado" : "Copiar")
        .accessibilityLabel(copied ? "Copiado" : "Copiar")
    }
}

extension View {
    func settingsFootnote() -> some View {
        font(.footnote).foregroundStyle(.secondary)
    }
}
