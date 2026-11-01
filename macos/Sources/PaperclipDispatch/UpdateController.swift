import AppKit

/// Las versiones de Paperclip (el servidor): revisa si salió una nueva y la instala, pero solo cuando se lo
/// piden, porque actualizar reinicia Paperclip y corta lo que estén haciendo los agentes. Instala con el
/// comando oficial o, si el build trae uno (PAPERCLIP_UPDATE_SCRIPT), con ese script. Solo con el
/// Paperclip de esta Mac y su CLI. Lo que sabe lo deja en `AppStatus`, que muestran el botón de arriba a
/// la derecha (`UpdatesButton`) y Ajustes.
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
        publish()
    }

    func start() {
        guard isLocal else {
            unavailable = "Este Paperclip corre en otra computadora: se actualiza allá."
            publish()
            return
        }
        runCheck(showProgress: false)
        timer = Timer.scheduledTimer(withTimeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.runCheck(showProgress: false) }
        }
    }

    /// Desde el panel, Ajustes o el menú: el resultado se ve ahí mismo, sin alertas.
    func checkNow() {
        runCheck(showProgress: true)
    }

    private func runCheck(showProgress: Bool) {
        guard progress == nil, !checking, isLocal else { return }
        checking = showProgress
        publish()
        Task {
            let result = await Shell.run(["-c", Self.checkCommand])
            checking = false
            if result.status == Self.commandNotFound {
                unavailable = "Para ver versiones nuevas aquí hace falta el comando de Paperclip."
                checkError = nil
                publish()
                return
            }
            unavailable = nil
            guard result.status == 0, var check = Self.decode(result.output) else {
                checkError = result.tail(Self.errorTailLines)
                publish()
                return
            }
            if let previewTarget {
                check = Check(currentVersion: check.currentVersion, targetVersion: previewTarget, updateAvailable: true)
            }
            last = check
            lastCheckedAt = .now
            checkError = nil
            publish()
        }
    }

    private func publish() {
        status.paperclipVersion = last?.currentVersion
        status.latestVersion = last?.updateAvailable == true ? last?.targetVersion : nil
        status.checkingUpdate = checking
        status.updateCheckFailed = checkError != nil
        status.updateCheckError = checkError
        status.lastCheckedAt = lastCheckedAt
        status.updateProgress = progress
        status.updatesUnavailable = unavailable
    }

    static func releaseNotesURL(for version: String) -> URL {
        URL(string: releaseNotesBase + version) ?? URL(string: "https://github.com/paperclipai/paperclip/releases")!
    }

    /// «Actualizar…» del panel y de Ajustes: con una versión nueva pide confirmación y actualiza; si no,
    /// vuelve a revisar.
    func requestUpdate() {
        guard progress == nil else { return }
        guard let last, last.updateAvailable else {
            runCheck(showProgress: true)
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
                NSWorkspace.shared.open(Self.releaseNotesURL(for: available.targetVersion))
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
            publish()
            await showAlert("La actualización no terminó", result.tail(Self.errorTailLines))
            runCheck(showProgress: false)
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
        publish()
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
        publish()
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
