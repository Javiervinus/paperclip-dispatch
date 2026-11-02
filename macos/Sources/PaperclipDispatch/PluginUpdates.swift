import Foundation
import Observation
import os

/// Los plugins instalados en Paperclip y sus versiones nuevas, para actualizarlos desde el panel de
/// actualizaciones. Paperclip sabe actualizarlos (`POST /api/plugins/:id/upgrade`), pero su página no tiene
/// un botón para eso: solo el comando `paperclipai plugin upgrade`.
/// - Solo los instalados desde npm tienen versión nueva que buscar: la última publicada (`latest`). Los que
///   salen de una carpeta (`packagePath`) se muestran, pero se actualizan en esa carpeta: así la app nunca
///   cambia el plugin con el que alguien está trabajando.
/// - Actualizar lo puede hacer solo quien administra el Paperclip; los demás ven las versiones, sin botón.
/// - Lee con la sesión de la página: sin sesión, no muestra nada.
@MainActor
@Observable
final class PluginUpdates {
    struct Plugin: Identifiable, Equatable {
        enum Source: Equatable {
            /// El paquete de npm de donde Paperclip lo instaló.
            case npm(String)
            /// Una carpeta del computador donde corre Paperclip.
            case folder
        }

        let id: String
        let name: String
        var version: String
        let source: Source
        /// La última versión publicada, solo si es más nueva que la instalada.
        var latest: String?

        /// Su página en npm, con las novedades que publique el autor.
        var packageURL: URL? {
            guard case .npm(let package) = source else { return nil }
            return URL(string: "https://www.npmjs.com/package/\(package)")
        }
    }

    /// Los plugins cambian seguido (cada PR fusionado publica una versión): como la app, cada hora.
    static let checkInterval: TimeInterval = 60 * 60
    /// Al abrir la app, la página puede tardar en iniciar sesión: la primera lectura espera un poco.
    private static let firstCheckDelay: Duration = .seconds(20)
    private static let registryURL = URL(string: "https://registry.npmjs.org")!
    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "PaperclipDispatch", category: "plugin-updates")

    private(set) var plugins: [Plugin] = []
    /// Una revisión pedida a mano (el panel, el menú). Las automáticas no se muestran.
    private(set) var checking = false
    private(set) var lastCheckedAt: Date?
    /// Por qué falló la última revisión.
    private(set) var checkError: String?
    /// Si esta cuenta administra el Paperclip. Si no se pudo saber, se ofrece y Paperclip decide.
    private(set) var canUpdate = true
    /// El plugin que se está actualizando.
    private(set) var updatingID: String?
    /// Por qué falló la última actualización de cada plugin.
    private(set) var updateErrors: [String: String] = [:]

    /// Después de actualizar uno: la página no carga sola la versión nueva, hay que recargarla.
    @ObservationIgnored var onUpdated: (() -> Void)?

    @ObservationIgnored private let api: PaperclipAPI?
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var running = false

    init(api: PaperclipAPI) {
        self.api = api
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        session = URLSession(configuration: configuration)
    }

    /// Para los ensayos: estos plugins, sin Paperclip ni npm. «Actualizar» no hace nada.
    init(previewing plugins: [Plugin], updatingID: String? = nil) {
        api = nil
        session = .shared
        self.plugins = plugins
        self.updatingID = updatingID
        lastCheckedAt = .now
    }

    var available: [Plugin] { plugins.filter { $0.latest != nil } }

    var updating: Plugin? { plugins.first { $0.id == updatingID } }

    func start() {
        guard api != nil else { return }
        Task {
            try? await Task.sleep(for: Self.firstCheckDelay)
            await check()
        }
        timer = Timer.scheduledTimer(withTimeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.check() }
            }
        }
    }

    /// Desde el panel o el menú: el resultado se ve en el panel.
    func checkNow() {
        guard api != nil, !running else { return }
        checking = true
        Task {
            await check()
            checking = false
        }
    }

    private func check() async {
        guard let api, !running, updatingID == nil else { return }
        running = true
        defer { running = false }
        let records: [Lossy<Record>]
        do {
            records = try await api.get("api/plugins")
        } catch PaperclipAPI.APIError.signedOut {
            // Sin sesión (o sin acceso a la lista): no hay nada que mostrar.
            plugins = []
            checkError = nil
            return
        } catch {
            checkError = error.localizedDescription
            return
        }
        if let me: Me = try? await api.get("api/cli-auth/me") {
            canUpdate = me.isInstanceAdmin ?? true
        }
        var found: [Plugin] = []
        for record in records.compactMap(\.value) {
            let source: Plugin.Source = record.packagePath == nil ? .npm(record.packageName) : .folder
            var plugin = Plugin(
                id: record.id,
                name: record.manifestJson?.displayName ?? record.packageName,
                version: record.version,
                source: source
            )
            if case .npm(let package) = source, let latest = await latestVersion(of: package),
               Self.isNewer(latest, than: record.version) {
                plugin.latest = latest
            }
            found.append(plugin)
        }
        plugins = found
        lastCheckedAt = .now
        checkError = nil
        Self.log.info(
            "\(found.count) plugins, \(found.filter { $0.latest != nil }.count) with a new version, can update: \(self.canUpdate)"
        )
    }

    /// La versión `latest` en npm. `nil` si no se pudo saber (sin red, un paquete privado).
    private func latestVersion(of package: String) async -> String? {
        let url = Self.registryURL.appending(path: package).appending(path: "latest")
        guard let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return (try? JSONDecoder().decode(Published.self, from: data))?.version
    }

    /// «Actualizar» en el panel: Paperclip baja la versión nueva de npm y cambia solo ese plugin, sin
    /// reiniciarse ni parar a los agentes.
    func update(_ plugin: Plugin) {
        guard updatingID == nil else { return }
        // Ya, no cuando corra la tarea: así un segundo clic no pide lo mismo dos veces.
        updatingID = plugin.id
        Task {
            if await upgrade(plugin) { await finishUpdates() }
        }
    }

    /// «Actualizar todos»: uno tras otro, con una sola recarga de la página al final.
    func updateAll() {
        guard updatingID == nil, let first = available.first else { return }
        let pending = available
        updatingID = first.id
        Task {
            var updated = false
            for plugin in pending where await upgrade(plugin) {
                updated = true
            }
            if updated { await finishUpdates() }
        }
    }

    /// Pide la versión nueva a Paperclip. `true` si quedó instalada.
    private func upgrade(_ plugin: Plugin) async -> Bool {
        guard case .npm = plugin.source, let latest = plugin.latest else { return false }
        updatingID = plugin.id
        updateErrors[plugin.id] = nil
        defer { updatingID = nil }
        // Ensayo: nada que actualizar.
        guard let api else { return false }
        do {
            let record: Record = try await api.post(
                "api/plugins/\(plugin.id)/upgrade", ["version": latest], returning: Record.self
            )
            if record.status != "ready" {
                updateErrors[plugin.id] = String(localized: "Paperclip left it as “\(record.status)”.")
            }
            Self.log.info("updated \(plugin.name, privacy: .public) to \(record.version, privacy: .public)")
            if let index = plugins.firstIndex(where: { $0.id == plugin.id }) {
                plugins[index].version = record.version
                plugins[index].latest = nil
            }
            return true
        } catch PaperclipAPI.APIError.signedOut {
            updateErrors[plugin.id] = String(localized: "Only whoever runs this Paperclip can update its plugins.")
        } catch {
            updateErrors[plugin.id] = error.localizedDescription
        }
        return false
    }

    /// Después de actualizar: vuelve a leer la lista y recarga la página, que no carga sola la versión nueva.
    private func finishUpdates() async {
        // Una revisión que empezó antes volvería con la versión vieja: se espera a que termine y se revisa de
        // nuevo.
        while running { try? await Task.sleep(for: .milliseconds(200)) }
        await check()
        onUpdated?()
    }

    /// Compara versiones de npm (semver): `1.10.0` es más nueva que `1.9.2`, y `1.0.0` que `1.0.0-beta.1`.
    nonisolated static func isNewer(_ candidate: String, than installed: String) -> Bool {
        func split(_ version: String) -> (core: [Int], prerelease: [Substring]?) {
            let clean = version.split(separator: "+", maxSplits: 1).first ?? ""
            let parts = clean.split(separator: "-", maxSplits: 1)
            let core = (parts.first ?? "").split(separator: ".").map { Int($0) ?? 0 }
            return (core, parts.count > 1 ? parts[1].split(separator: ".") : nil)
        }
        let a = split(candidate), b = split(installed)
        for index in 0..<max(a.core.count, b.core.count) {
            let x = index < a.core.count ? a.core[index] : 0
            let y = index < b.core.count ? b.core[index] : 0
            if x != y { return x > y }
        }
        switch (a.prerelease, b.prerelease) {
        case (nil, nil): return false
        case (nil, .some): return true
        case (.some, nil): return false
        case let (x?, y?):
            for (p, q) in zip(x, y) where p != q {
                if let m = Int(p), let n = Int(q) { return m > n }
                return p > q
            }
            return x.count > y.count
        }
    }

    // MARK: - Lo que contestan Paperclip y npm

    private struct Record: Decodable {
        struct Manifest: Decodable {
            let displayName: String?
        }

        let id: String
        let packageName: String
        let version: String
        let status: String
        let packagePath: String?
        let manifestJson: Manifest?
    }

    private struct Me: Decodable {
        let isInstanceAdmin: Bool?
    }

    private struct Published: Decodable {
        let version: String
    }
}
