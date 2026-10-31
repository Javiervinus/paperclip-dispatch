import AppKit

/// El botón de arriba a la derecha con la versión de Paperclip. Si está al día lo dice, discreto; si sale
/// una versión nueva, se pinta del color de acento y la instala, pero solo cuando se lo piden: actualizar
/// reinicia Paperclip y corta lo que estén haciendo los agentes. Instala con el comando oficial o, si el
/// build trae uno (PAPERCLIP_UPDATE_SCRIPT), con ese script. Solo con el Paperclip de esta Mac y su CLI.
@MainActor
final class UpdateController {
    /// Lo que responde `paperclipai update --check --latest --json`.
    struct Check: Decodable {
        let currentVersion: String
        let targetVersion: String
        let updateAvailable: Bool
    }

    /// Paperclip saca versión cada una o dos semanas: con revisar cada seis horas basta.
    static let checkInterval: TimeInterval = 6 * 60 * 60
    static let checkCommand = "paperclipai update --check --latest --json"
    /// Sin entrada: si el CLI preguntara algo, falla en vez de quedarse esperando.
    private static let updateCommand = "paperclipai update --latest </dev/null"
    static let installCLICommand = "npm install -g paperclipai"
    /// Lo que devuelve zsh cuando no encuentra el comando.
    private static let commandNotFound: Int32 = 127
    private static let releaseNotesBase = "https://github.com/paperclipai/paperclip/releases/tag/v"
    private static let errorTailLines = 12
    /// Ensayo: abrir la app con `--args -PaperclipPreviewUpdate <versión>` finge que salió esa versión, para
    /// ver el botón sin esperar una de verdad. Ahí «Actualizar» muestra los pasos sin actualizar nada.
    private static let previewDefaultsKey = "PaperclipPreviewUpdate"
    private static let rehearsalStepDuration: Duration = .seconds(1.5)

    private let config: AppConfig
    /// Paperclip corre en esta Mac: el CLI de aquí es el suyo.
    private let isLocal: Bool
    private unowned let host: MainWindowController
    private let notifications: NotificationBridge
    private let status: AppStatus
    private let previewTarget = UserDefaults.standard.string(forKey: previewDefaultsKey)
    private let button = NSButton()
    private var last: Check?
    private var lastCheckedAt: Date?
    private var checkError: String?
    /// Por qué no se puede revisar desde aquí (otra computadora, falta el CLI): sin botón.
    private var unavailable: String?
    private var checking = false
    private var progress: String?
    private var timer: Timer?

    init(
        config: AppConfig,
        isLocal: Bool,
        host: MainWindowController,
        notifications: NotificationBridge,
        status: AppStatus
    ) {
        self.config = config
        self.isLocal = isLocal
        self.host = host
        self.notifications = notifications
        self.status = status
        button.bezelStyle = .glass
        button.controlSize = .large
        button.imagePosition = .imageLeading
        button.target = self
        button.action = #selector(buttonClicked)
        refreshButton()
    }

    func start() {
        guard isLocal else {
            unavailable = "Este Paperclip corre en otra computadora: se actualiza allá."
            refreshButton()
            return
        }
        runCheck(showProgress: false, announce: false)
        timer = Timer.scheduledTimer(withTimeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.runCheck(showProgress: false, announce: false) }
        }
    }

    /// Desde el menú: además avisa con una alerta si no hay nada nuevo o si falló.
    func check(userInitiated: Bool) {
        runCheck(showProgress: userInitiated, announce: userInitiated)
    }

    /// Desde Ajustes: sin alertas, porque el resultado se ve ahí mismo.
    func checkNow() {
        runCheck(showProgress: true, announce: false)
    }

    private func runCheck(showProgress: Bool, announce: Bool) {
        guard progress == nil, !checking, isLocal else { return }
        checking = showProgress
        refreshButton()
        Task {
            let result = await Shell.run(["-c", Self.checkCommand])
            checking = false
            if result.status == Self.commandNotFound {
                unavailable = "Para ver versiones nuevas aquí hace falta el comando de Paperclip."
                checkError = nil
                refreshButton()
                return
            }
            unavailable = nil
            guard result.status == 0, var check = Self.decode(result.output) else {
                checkError = result.tail(Self.errorTailLines)
                refreshButton()
                if announce {
                    await showAlert("No pude revisar si hay versión nueva", checkError ?? "")
                }
                return
            }
            if let previewTarget {
                check = Check(currentVersion: check.currentVersion, targetVersion: previewTarget, updateAvailable: true)
            }
            last = check
            lastCheckedAt = .now
            checkError = nil
            refreshButton()
            if announce, !check.updateAvailable {
                await showAlert("Paperclip está al día", "Tienes la \(check.currentVersion), la última versión estable.")
            }
        }
    }

    private func refreshButton() {
        defer { host.setUpdateButton(button, visible: !button.title.isEmpty) }
        status.paperclipVersion = last?.currentVersion
        status.latestVersion = last?.updateAvailable == true ? last?.targetVersion : nil
        status.checkingUpdate = checking
        status.updateCheckFailed = checkError != nil
        status.updateCheckError = checkError
        status.lastCheckedAt = lastCheckedAt
        status.updateProgress = progress
        status.updatesUnavailable = unavailable
        button.isEnabled = progress == nil && !checking
        button.tintProminence = .none
        if unavailable != nil {
            button.title = ""
        } else if let progress {
            show(progress, symbol: "arrow.down.circle.fill", color: nil)
            button.tintProminence = .primary
            button.toolTip = "No cierres la app hasta que termine."
        } else if checking {
            show("Revisando…", symbol: "arrow.clockwise", color: nil)
            button.toolTip = nil
        } else if let last, last.updateAvailable {
            show("Actualizar a \(last.targetVersion)", symbol: "arrow.down.circle.fill", color: nil)
            button.tintProminence = .primary
            button.toolTip = "Tienes la \(last.currentVersion). Paperclip no se actualiza solo: tú eliges cuándo."
        } else if let last {
            show("Al día · \(last.currentVersion)", symbol: "checkmark.circle.fill", color: .systemGreen)
            let time = (lastCheckedAt ?? .now).formatted(date: .omitted, time: .shortened)
            button.toolTip = "Es la última versión estable de Paperclip. Revisado a las \(time); clic para revisar de nuevo."
        } else if let checkError {
            show("No pude revisar", symbol: "exclamationmark.triangle.fill", color: .systemOrange)
            button.toolTip = "\(checkError)\n\nClic para reintentar."
        } else {
            // Todavía no termina la primera revisión.
            button.title = ""
        }
    }

    /// `color` pinta el fondo del símbolo y deja blanco el dibujo de adentro (la palomita, el signo).
    private func show(_ title: String, symbol: String, color: NSColor?) {
        button.title = title
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        button.image = color.flatMap { image?.withSymbolConfiguration(.init(paletteColors: [.white, $0])) } ?? image
    }

    @objc private func buttonClicked() {
        requestUpdate()
    }

    /// Lo mismo que el botón: con una versión nueva pide confirmación y actualiza; si no, vuelve a revisar.
    func requestUpdate() {
        guard progress == nil else { return }
        guard let last, last.updateAvailable else {
            runCheck(showProgress: true, announce: false)
            return
        }
        confirmUpdate(last)
    }

    private func confirmUpdate(_ available: Check) {
        let script = config.updateScript
        if let script, !FileManager.default.fileExists(atPath: script.path) {
            Task {
                await showAlert(
                    "No encuentro el script para actualizar",
                    "Esta app se armó para actualizar con \(script.path), que ya no está."
                )
            }
            return
        }
        let alert = NSAlert()
        alert.messageText = "¿Actualizar Paperclip a la \(available.targetVersion)?"
        alert.informativeText = """
            Tienes la \(available.currentVersion). Paperclip se reinicia y corta lo que estén haciendo \
            los agentes. Antes respalda la base; tarda uno o dos minutos.
            """
        if previewTarget != nil {
            alert.informativeText += "\n\nEsto es un ensayo: muestra los pasos sin actualizar nada."
        }
        alert.addButton(withTitle: "Actualizar")
        alert.addButton(withTitle: "Cancelar")
        alert.addButton(withTitle: "Ver novedades")
        Task {
            switch await host.present(alert) {
            case .alertFirstButtonReturn:
                if previewTarget != nil {
                    await rehearse(script: script, target: available.targetVersion)
                } else {
                    await runUpdate(script.map { [$0.path] } ?? ["-c", Self.updateCommand], target: available.targetVersion)
                }
            case .alertThirdButtonReturn:
                if let url = URL(string: Self.releaseNotesBase + available.targetVersion) {
                    NSWorkspace.shared.open(url)
                }
            default:
                break
            }
        }
    }

    private func runUpdate(_ arguments: [String], target: String) async {
        setProgress("Actualizando…")
        // Un script propio puede contar sus pasos («2/5 Deteniendo el servicio…»): el botón los muestra.
        let result = await Shell.run(arguments) { [weak self] line in
            guard let step = Self.step(in: line) else { return }
            Task { @MainActor in self?.setProgress(step) }
        }
        progress = nil
        if result.status == 0 {
            finish(target: target)
            host.reload()
        } else {
            refreshButton()
            await showAlert("La actualización no terminó", result.tail(Self.errorTailLines))
            runCheck(showProgress: false, announce: false)
        }
    }

    /// El ensayo pasa por los mismos pasos que imprime el script, leídos de él, sin correrlo.
    private func rehearse(script: URL?, target: String) async {
        let lines = script.flatMap { try? String(contentsOf: $0, encoding: .utf8) }?.split(separator: "\n") ?? []
        let steps = lines.compactMap { line -> String? in
            guard let printed = line.firstMatch(of: #/^\s*print "(.+)"/#) else { return nil }
            return Self.step(in: String(printed.1))
        }
        setProgress("Actualizando…")
        for step in steps {
            try? await Task.sleep(for: Self.rehearsalStepDuration)
            setProgress(step)
        }
        try? await Task.sleep(for: Self.rehearsalStepDuration)
        progress = nil
        finish(target: target)
    }

    private func finish(target: String) {
        last = Check(currentVersion: target, targetVersion: target, updateAvailable: false)
        lastCheckedAt = .now
        refreshButton()
        notifications.show(
            id: "paperclip-update",
            tag: "paperclip-update",
            title: previewTarget == nil ? "Paperclip actualizado" : "Paperclip actualizado (ensayo)",
            body: "Ya está en la \(target).",
            href: nil
        )
    }

    private func setProgress(_ text: String) {
        progress = text
        refreshButton()
    }

    /// «2/5 Deteniendo el servicio…» → «Actualizando 2/5…». Se llama también desde la lectura de la salida.
    nonisolated private static func step(in line: String) -> String? {
        guard let step = line.firstMatch(of: #/^(\d+)/(\d+) /#) else { return nil }
        return "Actualizando \(step.1)/\(step.2)…"
    }

    private func showAlert(_ title: String, _ message: String) async {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "Aceptar")
        _ = await host.present(alert)
    }

    /// El shell de inicio puede imprimir algo antes: se toma solo el objeto JSON.
    static func decode(_ output: String) -> Check? {
        guard let start = output.firstIndex(of: "{"), let end = output.lastIndex(of: "}"), start < end else {
            return nil
        }
        return try? JSONDecoder().decode(Check.self, from: Data(output[start...end].utf8))
    }
}
