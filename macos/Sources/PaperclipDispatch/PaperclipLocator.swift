import AppKit

/// Un Paperclip instalado en esta Mac, como lo deja su CLI en `~/.paperclip/instances/<id>/`.
struct LocalPaperclip: Equatable, Sendable {
    let instanceId: String
    /// La dirección que da Paperclip (`dashboardUrl`, la de su login); sin ella, la de esta Mac.
    let url: URL
    let port: Int
    /// Corre como servicio de launchd (`paperclipai service install`): se enciende sin abrir la Terminal.
    let hasService: Bool
}

/// Lo que responde `GET /api/health`, que no pide sesión. En modo `authenticated` no trae la versión.
struct PaperclipHealth: Decodable, Equatable, Sendable {
    let status: String
    let deploymentMode: String
    let version: String?

    /// Hay que iniciar sesión en la página (en `local_trusted` se entra directo).
    var needsSignIn: Bool { deploymentMode != "local_trusted" }
}

/// Busca Paperclip en esta Mac, comprueba direcciones y lo enciende o lo instala con sus comandos oficiales.
/// Lee lo mismo que su CLI: `PAPERCLIP_HOME` (por defecto `~/.paperclip`) y `PAPERCLIP_INSTANCE_ID`.
enum PaperclipLocator {
    enum Detection: Equatable, Sendable {
        /// Responde: se puede abrir.
        case running(LocalPaperclip, PaperclipHealth)
        /// Está instalado, pero no responde.
        case stopped(LocalPaperclip)
        case notInstalled
    }

    enum ProbeError: Error, Equatable {
        case unreachable
        case notPaperclip
        case starting

        var message: String {
            switch self {
            case .unreachable: String(localized: "It isn’t responding. Check the address and that Paperclip is running.")
            case .notPaperclip: String(localized: "It responds, but it isn’t Paperclip.")
            case .starting: String(localized: "Paperclip is starting up: wait a few seconds.")
            }
        }
    }

    static let defaultPort = 3100
    /// El servicio de launchd de la instancia `default`; las otras le suman su id, como su CLI.
    static let serviceLabel = "ing.paperclip.paperclipai"
    static let installCommand = "npx paperclipai@latest onboard --yes"
    static let websiteURL = AppInfo.paperclipURL
    static let nodeDownloadURL = URL(string: String(localized: "https://nodejs.org/en/download", comment: "La página de descarga de Node.js en el idioma de la app."))
    /// Node.js que pide Paperclip (campo `engines` de su paquete).
    static let minimumNode = (major: 24, minor: 11)
    private static let probeTimeout: TimeInterval = 3
    /// `node -v` contesta al instante; si el shell de inicio se cuelga, mejor decir que no está.
    private static let nodeCheckTimeout: TimeInterval = 10

    // MARK: Buscar

    static func detect() async -> Detection {
        guard let local = installed() else {
            // Sin instalación conocida, igual puede estar corriendo en el puerto de siempre.
            let url = loopbackURL(port: defaultPort)
            if case let .success(health) = await probe(url) {
                let local = LocalPaperclip(instanceId: defaultInstanceId, url: url, port: defaultPort, hasService: false)
                return .running(local, health)
            }
            return .notInstalled
        }
        if case let .success(health) = await probe(local.url) { return .running(local, health) }
        // La dirección de Paperclip puede no responder (p. ej. Tailscale apagado) con el servidor encendido.
        let loopback = loopbackURL(port: local.port)
        if loopback != local.url, case let .success(health) = await probe(loopback) {
            return .running(LocalPaperclip(instanceId: local.instanceId, url: loopback, port: local.port, hasService: local.hasService), health)
        }
        return .stopped(local)
    }

    /// La instancia que usaría el CLI, si existe su configuración.
    static func installed() -> LocalPaperclip? {
        let instances = home.appending(path: "instances", directoryHint: .isDirectory)
        var ids = [defaultInstanceId]
        if let others = try? FileManager.default.contentsOfDirectory(atPath: instances.path) {
            ids += others.sorted().filter { $0 != defaultInstanceId }
        }
        for id in ids {
            let folder = instances.appending(path: id, directoryHint: .isDirectory)
            guard let config = readJSON(folder.appending(path: "config.json")) else { continue }
            let runtime = readJSON(folder.appending(path: "runtime-info.json"))
            let server = config["server"] as? [String: Any]
            let auth = config["auth"] as? [String: Any]
            let port = (runtime?["port"] as? Int) ?? (server?["port"] as? Int) ?? defaultPort
            let url = [runtime?["dashboardUrl"], auth?["publicBaseUrl"]]
                .compactMap { ($0 as? String).flatMap(serverURL) }
                .first ?? loopbackURL(port: port)
            return LocalPaperclip(instanceId: id, url: url, port: port, hasService: hasService(id))
        }
        return nil
    }

    /// Si esa dirección es la del Paperclip de esta Mac: la de su instalación o una de la propia Mac.
    static func isOnThisMac(_ url: URL) -> Bool {
        let host = url.host()?.lowercased() ?? ""
        if ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host) { return true }
        return installed().map { $0.url.host()?.lowercased() == host } ?? false
    }

    /// Comprueba que en esa dirección haya un Paperclip.
    static func probe(_ url: URL) async -> Result<PaperclipHealth, ProbeError> {
        var request = URLRequest(url: url.appending(path: "api/health"), timeoutInterval: probeTimeout)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = probeTimeout
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        guard let (data, response) = try? await session.data(for: request) else { return .failure(.unreachable) }
        guard let health = try? JSONDecoder().decode(PaperclipHealth.self, from: data) else {
            return .failure(.notPaperclip)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status), health.status == "ok" else { return .failure(.starting) }
        return .success(health)
    }

    /// Lo que escribe la persona («192.168.1.20:3100», «https://mac.tail…ts.net») como dirección completa.
    static func serverURL(_ text: String) -> URL? {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "http://" + text }
        guard var components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host, !host.isEmpty
        else { return nil }
        // Como la escribe WebKit (esquema y servidor en minúsculas, sin el puerto por defecto), para que
        // `AppConfig.isInternal` reconozca las páginas de Paperclip aunque se haya escrito «Mi-Mac.local».
        components.scheme = scheme
        components.host = host.lowercased()
        if components.port == (scheme == "https" ? 443 : 80) { components.port = nil }
        // Solo el servidor: Paperclip abre su propia página de inicio.
        components.path = ""
        components.query = nil
        components.fragment = nil
        return components.url
    }

    // MARK: Encender e instalar

    /// Enciende un Paperclip apagado: con su servicio de launchd o, si no tiene, en la Terminal. Devuelve un
    /// error para mostrar, o nil si lo pidió (arranca en unos segundos).
    static func start(_ local: LocalPaperclip) async -> String? {
        guard local.hasService else {
            let instance = shellQuoted(local.instanceId)
            openInTerminal(
                named: "start-paperclip",
                title: String(localized: "Starting Paperclip. Keep this window open: it runs here."),
                command: "if command -v paperclipai >/dev/null; then paperclipai run --instance \(instance); "
                    + "else npx paperclipai@latest run --instance \(instance); fi"
            )
            return nil
        }
        return await startService(local.instanceId)
    }

    // MARK: Servicio

    /// Enciende el servicio sin tocar si arranca al iniciar sesión. Devuelve un error para mostrar, o nil.
    ///
    /// No usa `paperclipai service start`: su CLI lee mal si el servicio está desactivado (busca `=> true`
    /// en `launchctl print-disabled`, y macOS 26 escribe `=> disabled`), así que siempre lo reactiva y
    /// apagaría «Iniciar Paperclip al iniciar sesión» sin avisar.
    static func startService(_ instanceId: String) async -> String? {
        let target = serviceTarget(instanceId)
        let kickstart = await Shell.run(["-c", "launchctl kickstart \(target)"])
        if kickstart.status == 0 { return nil }
        // Si no está cargado, se carga (y arranca solo: RunAtLoad). launchd no carga un servicio desactivado:
        // se activa para cargarlo y se vuelve a desactivar, que no lo detiene.
        let disabled = await startsAtLogin(instanceId) == false
        if disabled { _ = await Shell.run(["-c", "launchctl enable \(target)"]) }
        let bootstrap = await Shell.run(["-c", "launchctl bootstrap \(domain) \(shellQuoted(servicePlist(instanceId).path))"])
        if disabled { _ = await Shell.run(["-c", "launchctl disable \(target)"]) }
        return bootstrap.status == 0 ? nil : String(localized: "macOS couldn’t start the Paperclip service: \(bootstrap.tail(2))")
    }

    /// Si el servicio arranca al iniciar sesión, o nil si no se pudo leer. Es lo que cambia
    /// `paperclipai service install --no-start-on-login`: `launchctl enable` o `disable`.
    static func startsAtLogin(_ instanceId: String) async -> Bool? {
        let result = await Shell.run(["-c", "launchctl print-disabled \(domain)"])
        guard result.status == 0 else { return nil }
        let label = "\"\(serviceLabel(instanceId))\""
        guard let line = result.output.split(separator: "\n").first(where: { $0.contains(label) }) else { return true }
        return !(line.contains("=> disabled") || line.contains("=> true"))
    }

    /// Activa o desactiva el arranque al iniciar sesión, sin encender ni apagar el servicio: los agentes
    /// siguen con lo que estaban haciendo.
    static func setStartsAtLogin(_ enabled: Bool, instanceId: String) async -> String? {
        let result = await Shell.run(["-c", "launchctl \(enabled ? "enable" : "disable") \(serviceTarget(instanceId))"])
        return result.status == 0 ? nil : result.tail(2)
    }

    /// Instala el servicio con el comando oficial: lo enciende ya y al iniciar sesión.
    static func installService(_ instanceId: String) async -> Shell.Result {
        await Shell.run(["-c", "paperclipai service install --instance \(shellQuoted(instanceId))"])
    }

    static func hasService(_ instanceId: String) -> Bool {
        FileManager.default.fileExists(atPath: servicePlist(instanceId).path)
    }

    /// Abre la Terminal con el instalador oficial (`onboard --yes`: modo local, sin login, y lo enciende).
    static func openInstaller() {
        openInTerminal(
            named: "install-paperclip",
            title: String(localized: "Installing Paperclip with its official command. When it’s done, it keeps running in this window."),
            command: installCommand
        )
    }

    /// La versión de Node.js del shell de inicio, o nil si no está.
    static func nodeVersion() async -> (major: Int, minor: Int, text: String)? {
        let result = await Shell.run(["-c", "node -v"], timeout: nodeCheckTimeout)
        guard result.status == 0,
              let match = result.output.firstMatch(of: #/v(\d+)\.(\d+)\.\d+/#),
              let major = Int(match.1), let minor = Int(match.2)
        else { return nil }
        return (major, minor, String(match.0))
    }

    static func meetsNodeRequirement(_ version: (major: Int, minor: Int, text: String)) -> Bool {
        (version.major, version.minor) >= minimumNode
    }

    /// Un `.command` en la caché de la app, que macOS abre en la Terminal sin pedir permisos. Usa el shell de
    /// inicio, con el PATH de node y npx.
    static func openInTerminal(named name: String, title: String, command: String) {
        let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: Bundle.main.bundleIdentifier ?? AppConfig.appName, directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let script = folder.appending(path: "\(name).command")
        let text = """
            #!/bin/zsh -l
            clear
            print -P "%B\(title.replacingOccurrences(of: "\"", with: "'"))%b"
            print
            \(command)
            """
        guard (try? text.write(to: script, atomically: true, encoding: .utf8)) != nil else { return }
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        NSWorkspace.shared.open(script)
    }

    // MARK: Rutas

    private static var home: URL {
        if let custom = ProcessInfo.processInfo.environment["PAPERCLIP_HOME"], !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appending(path: ".paperclip", directoryHint: .isDirectory)
    }

    private static var defaultInstanceId: String {
        ProcessInfo.processInfo.environment["PAPERCLIP_INSTANCE_ID"].flatMap { $0.isEmpty ? nil : $0 } ?? "default"
    }

    private static var domain: String { "gui/\(getuid())" }

    private static func serviceLabel(_ instanceId: String) -> String {
        instanceId == "default" ? serviceLabel : "\(serviceLabel).\(instanceId)"
    }

    private static func serviceTarget(_ instanceId: String) -> String {
        shellQuoted("\(domain)/\(serviceLabel(instanceId))")
    }

    private static func servicePlist(_ instanceId: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/LaunchAgents/\(serviceLabel(instanceId)).plist")
    }

    private static func loopbackURL(port: Int) -> URL {
        URL(string: "http://127.0.0.1:\(port)")!
    }

    /// Entre comillas simples para zsh: el id de la instancia es el nombre de una carpeta y puede traer
    /// espacios o comillas.
    private static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func readJSON(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
