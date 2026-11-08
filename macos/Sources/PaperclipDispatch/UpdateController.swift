import AppKit

/// Las versiones de Paperclip (el servidor): revisa si salió una nueva y la instala, pero solo cuando se lo
/// piden, porque actualizar reinicia Paperclip y corta lo que estén haciendo los agentes. Instala con el
/// CLI oficial (`updateWithCLI`) o, si el build trae uno (PAPERCLIP_UPDATE_SCRIPT), con ese script. Solo con el
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

    /// Lo que responde `paperclipai service status --json`. `health` es el `/api/health` sin sesión: si
    /// Paperclip pide iniciar sesión, no trae la versión.
    private struct ServiceStatus: Decodable {
        struct Health: Decodable {
            let ok: Bool
            let serverVersion: String?
        }

        let active: Bool
        let health: Health?
    }

    /// Paperclip saca versión cada una o dos semanas: con revisar cada seis horas basta.
    static let checkInterval: TimeInterval = 6 * 60 * 60
    static let checkCommand = "paperclipai update --check --latest --json"
    /// Sin entrada: si el CLI preguntara algo, falla en vez de quedarse esperando.
    private static let updateCommand = "paperclipai update --latest </dev/null"
    /// Para actualizar con el servicio detenido (ver `updateWithCLI`). El respaldo va aparte y antes, con la
    /// base andando: con el servicio detenido, la base embebida también lo está y el de `update` fallaría.
    private static let serviceStatusCommand = "paperclipai service status --json"
    private static let backupCommand = "paperclipai db:backup"
    private static let serviceStopCommand = "paperclipai service stop"
    private static let serviceStartCommand = "paperclipai service start"
    private static let updateStoppedCommand = "paperclipai update --latest --no-backup </dev/null"
    private static let stoppedUpdateSteps = 4
    /// Detenerse tarda unos segundos (cierra las conexiones y la base); arrancar, un poco más si hay
    /// migraciones.
    private static let stopTimeout: Duration = .seconds(60)
    private static let startTimeout: Duration = .seconds(180)
    private static let servicePollInterval: Duration = .seconds(1)
    static let installCLICommand = "npm install -g paperclipai"
    /// Lo que devuelve zsh cuando no encuentra el comando.
    private static let commandNotFound: Int32 = 127
    /// Con `--check`, el CLI sale con 0 si está al día y con 10 si hay una versión nueva: las dos son
    /// respuestas buenas.
    private static let checkSuccessStatuses: Set<Int32> = [0, 10]
    /// Las versiones publicadas de Paperclip; cada una tiene su página en `tag/v<versión>`.
    private static let releasesURL = URL(string: "https://github.com/paperclipai/paperclip/releases")!
    /// Un solo aviso de «Paperclip actualizado»: el de la próxima vez reemplaza al anterior.
    private static let updatedNotificationID = "paperclip-update"
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
            unavailable = String(localized: "This Paperclip runs on another computer: update it there.")
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
                unavailable = String(localized: "To see new versions here, you need the Paperclip command.")
                checkError = nil
                publish()
                return
            }
            unavailable = nil
            guard var check = Self.decode(result) else {
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
        status.updateCheckError = checkError
        status.lastCheckedAt = lastCheckedAt
        status.updateProgress = progress
        status.updatesUnavailable = unavailable
    }

    static func releaseNotesURL(for version: String) -> URL {
        releasesURL.appending(path: "tag/v\(version)")
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
                    String(localized: "Couldn’t find the update script"),
                    String(localized: "This app was built to update with \(script.path), which is no longer there.")
                )
            }
            return
        }
        let alert = NSAlert()
        alert.messageText = String(localized: "Update Paperclip to \(available.targetVersion)?")
        alert.informativeText = String(localized: """
            You have \(available.currentVersion). Paperclip restarts and interrupts whatever the agents are \
            doing. It backs up the database first and takes a minute or two.
            """)
        if previewTarget != nil {
            alert.informativeText += "\n\n" + String(localized: "This is a rehearsal: it shows the steps without updating anything.")
        }
        alert.addButton(withTitle: String(localized: "Update"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.addButton(withTitle: String(localized: "See What’s New"))
        Task {
            switch await host.present(alert) {
            case .alertFirstButtonReturn:
                if previewTarget != nil {
                    await rehearse(script: script, target: available.targetVersion)
                } else if let script {
                    // Un script propio puede contar sus pasos («2/5 Deteniendo el servicio…»): el botón los muestra.
                    await runUpdate(target: available.targetVersion) {
                        await Shell.run([script.path]) { [weak self] line in
                            guard let step = Self.step(in: line) else { return }
                            Task { @MainActor in self?.setProgress(step) }
                        }
                    }
                } else {
                    await runUpdate(target: available.targetVersion) { await self.updateWithCLI() }
                }
            case .alertThirdButtonReturn:
                NSWorkspace.shared.open(Self.releaseNotesURL(for: available.targetVersion))
            default:
                break
            }
        }
    }

    private func runUpdate(target: String, _ perform: () async -> Shell.Result) async {
        setProgress(String(localized: "Updating…"))
        let result = await perform()
        progress = nil
        if result.status == 0 {
            finish(target: target)
            host.reload()
        } else {
            publish()
            await showAlert(String(localized: "The update didn’t finish"), result.tail(Self.errorTailLines))
            runCheck(showProgress: false)
        }
    }

    /// Con el CLI oficial. Si Paperclip pide iniciar sesión, su `/api/health` no dice la versión, y
    /// `paperclipai update` da por fallida toda actualización hecha con el servicio andando: la revierte
    /// aunque Paperclip arrancó bien (paperclipai/paperclip#13697). Con el servicio detenido no hace esa
    /// prueba, así que ahí se respalda, se detiene, se actualiza y se vuelve a arrancar.
    private func updateWithCLI() async -> Shell.Result {
        guard let status = await Self.serviceStatus(), status.active, let health = status.health,
              health.serverVersion == nil
        else {
            return await Shell.run(["-c", Self.updateCommand])
        }
        setStep(1)
        let backup = await Shell.run(["-c", Self.backupCommand])
        guard backup.status == 0 else { return backup }
        setStep(2)
        _ = await Shell.run(["-c", Self.serviceStopCommand])
        guard await Self.waitForService(within: Self.stopTimeout, until: { !$0.active }) else {
            return Shell.Result(status: 1, output: String(localized: "Paperclip didn’t stop in time, so it wasn’t updated."))
        }
        setStep(3)
        let update = await Shell.run(["-c", Self.updateStoppedCommand])
        // Arranca aunque la actualización haya fallado: Paperclip vuelve con la versión que quedó.
        setStep(4)
        let start = await Shell.run(["-c", Self.serviceStartCommand])
        let healthy = await Self.waitForService(within: Self.startTimeout) { $0.active && $0.health?.ok == true }
        if update.status != 0 { return update }
        guard healthy else {
            return Shell.Result(
                status: start.status == 0 ? 1 : start.status,
                output: start.output + "\n" + String(localized: "Paperclip was updated but didn’t start again. Open it with “paperclipai service start”.")
            )
        }
        return update
    }

    private func setStep(_ number: Int) {
        setProgress(Self.stepLabel(String(number), of: String(Self.stoppedUpdateSteps)))
    }

    private static func serviceStatus() async -> ServiceStatus? {
        let result = await Shell.run(["-c", serviceStatusCommand])
        guard result.status == 0,
              let start = result.output.firstIndex(of: "{"), let end = result.output.lastIndex(of: "}"), start < end
        else { return nil }
        return try? JSONDecoder().decode(ServiceStatus.self, from: Data(result.output[start...end].utf8))
    }

    /// Pregunta por el servicio hasta que cumpla `condition` o se acabe el tiempo.
    private static func waitForService(
        within timeout: Duration,
        until condition: (ServiceStatus) -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let status = await serviceStatus(), condition(status) { return true }
            try? await Task.sleep(for: servicePollInterval)
        }
        return false
    }

    /// El ensayo pasa por los mismos pasos que imprime el script, leídos de él, sin correrlo.
    private func rehearse(script: URL?, target: String) async {
        let lines = script.flatMap { try? String(contentsOf: $0, encoding: .utf8) }?.split(separator: "\n") ?? []
        let steps = lines.compactMap { line -> String? in
            guard let printed = line.firstMatch(of: #/^\s*print "(.+)"/#) else { return nil }
            return Self.step(in: String(printed.1))
        }
        setProgress(String(localized: "Updating…"))
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
            id: Self.updatedNotificationID,
            tag: Self.updatedNotificationID,
            title: previewTarget == nil ? String(localized: "Paperclip updated") : String(localized: "Paperclip updated (rehearsal)"),
            body: String(localized: "It’s now on \(target)."),
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
        return stepLabel(String(step.1), of: String(step.2))
    }

    nonisolated private static func stepLabel(_ number: String, of total: String) -> String {
        String(localized: "Updating \(number)/\(total)…")
    }

    private func showAlert(_ title: String, _ message: String) async {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: String(localized: "OK"))
        _ = await host.present(alert)
    }

    /// La respuesta de `checkCommand`. El shell de inicio puede imprimir algo antes: se toma solo el objeto JSON.
    static func decode(_ result: Shell.Result) -> Check? {
        let output = result.output
        guard checkSuccessStatuses.contains(result.status),
              let start = output.firstIndex(of: "{"), let end = output.lastIndex(of: "}"), start < end
        else {
            return nil
        }
        return try? JSONDecoder().decode(Check.self, from: Data(output[start...end].utf8))
    }
}
