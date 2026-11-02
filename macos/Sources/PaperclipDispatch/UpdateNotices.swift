import Foundation
import Observation

/// Avisa cuando sale una versión nueva de esta app, de Paperclip o de un plugin: anima a actualizar sin apurar.
/// - Mirando la ventana, con la píldora de abajo (`UpdatePill`). Afuera (otra app, la ventana cerrada), con un
///   aviso de macOS, y la píldora queda esperando: sale al volver a la ventana.
/// - Una vez por versión y sin sonido. La misma versión nunca se avisa dos veces (se guarda cuál se avisó), ni
///   siquiera la que salió con los avisos apagados.
/// - Los plugins sacan versiones seguido: van todos juntos y, como mucho, una vez al día. Solo si esta cuenta
///   puede actualizarlos.
/// - Se da por visto al abrir su panel (el de actualizaciones o el de plugins; también con «Ver» o un clic en
///   el aviso) o con la × de la píldora: se va de la píldora y de la lista de macOS. Con su panel ya abierto
///   no avisa. Cuando ya no hay nada que actualizar, también se quita.
/// Se apaga en Ajustes → Avisos o con la campana del panel (`Preferences.updateNotifications`).
@MainActor
final class UpdateNotices {
    /// En este orden van en la píldora.
    enum Kind: String, CaseIterable, Comparable {
        case dispatch, paperclip, plugins

        /// El del aviso en macOS: el de una versión nueva reemplaza al anterior del mismo tipo.
        var identifier: String { "update-\(rawValue)" }

        /// Dónde se ve: los plugins tienen su botón y su panel.
        var panel: Panel { self == .plugins ? .plugins : .updates }

        static func < (lhs: Kind, rhs: Kind) -> Bool {
            allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
        }
    }

    /// Los dos paneles: el del botón de actualizaciones y el del botón de los plugins.
    enum Panel: String {
        case updates, plugins
    }

    /// Lo que dice el aviso de macOS.
    struct Notice: Equatable {
        let title: String
        let body: String
    }

    /// Como mucho un aviso de plugins al día, aunque salgan varias versiones.
    static let pluginInterval: TimeInterval = 24 * 60 * 60
    /// Al volver a la ventana, lo que se espera antes de mostrar la píldora: que primero se vea la página.
    private static let returnDelay: Duration = .seconds(1)
    /// Con la ventana al frente pero algo encima (una hoja, el recordatorio de avisos): cada cuánto se vuelve a
    /// intentar.
    private static let retryInterval: Duration = .seconds(3)

    private enum Key {
        static let dispatch = "notifiedDispatchVersion"
        static let paperclip = "notifiedPaperclipVersion"
        /// La última versión avisada de cada plugin, por su id.
        static let plugins = "notifiedPluginVersions"
        static let pluginsAt = "notifiedPluginsAt"
    }

    let pill = UpdatePill()

    private let app: AppUpdater
    private let status: AppStatus
    private let plugins: PluginUpdates
    private let preferences: Preferences
    private let notifications: NotificationBridge
    private let defaults: UserDefaults
    /// Si se está mirando la ventana: decide entre la píldora y el aviso de macOS.
    private let isInFront: () -> Bool
    /// Si la píldora puede salir ya: la ventana al frente, sin hojas ni el recordatorio de avisos.
    private let canPresent: () -> Bool
    private let isPanelOpen: (Panel) -> Bool
    /// Lo que espera en la píldora, sin ver todavía.
    private var waiting: [Kind: UpdatePill.Item] = [:]
    /// Los avisos que puede haber en la lista de macOS. Al abrir la app no se sabe: pueden quedar de antes.
    private var shown = Set(Kind.allCases)
    private var presenting: Task<Void, Never>?

    init(
        app: AppUpdater,
        status: AppStatus,
        plugins: PluginUpdates,
        preferences: Preferences,
        notifications: NotificationBridge,
        defaults: UserDefaults = .standard,
        isInFront: @escaping () -> Bool,
        canPresent: @escaping () -> Bool,
        isPanelOpen: @escaping (Panel) -> Bool,
        openPanel: @escaping (Panel) -> Void
    ) {
        self.app = app
        self.status = status
        self.plugins = plugins
        self.preferences = preferences
        self.notifications = notifications
        self.defaults = defaults
        self.isInFront = isInFront
        self.canPresent = canPresent
        self.isPanelOpen = isPanelOpen
        // «Ver»: el panel de actualizaciones si hay algo de la app o de Paperclip; si son solo plugins, el suyo.
        pill.onSee = { [weak self] in
            guard let self else { return }
            let panel: Panel = waiting.keys.contains { $0.panel == .updates } ? .updates : .plugins
            acknowledge(Kind.allCases)
            openPanel(panel)
        }
        pill.onDismiss = { [weak self] in self?.acknowledge(Kind.allCases) }
    }

    func start() {
        observe()
    }

    /// La ventana volvió al frente: lo que se avisó afuera sale también aquí.
    func cameToFront() {
        presentWhenPossible(after: Self.returnDelay)
    }

    /// Se abrió uno de los paneles: ahí se ve lo suyo.
    func panelOpened(_ panel: Panel) {
        acknowledge(Kind.allCases.filter { $0.panel == panel })
    }

    /// Vuelve a mirar cada vez que cambia algo: una revisión (cambia su hora), una versión, los avisos.
    private func observe() {
        withObservationTracking {
            evaluate()
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
    }

    private func evaluate() {
        let enabled = preferences.updateNotifications
        _ = (app.lastCheckedAt, status.lastCheckedAt, plugins.lastCheckedAt)

        switch app.phase {
        case .available(let release):
            offer(.dispatch, version: release.version, key: Key.dispatch, enabled: enabled) {
                (Self.dispatchNotice(release.version, ready: false), Self.dispatchItem(release.version, ready: false))
            }
        case .ready(let release):
            offer(.dispatch, version: release.version, key: Key.dispatch, enabled: enabled) {
                (Self.dispatchNotice(release.version, ready: true), Self.dispatchItem(release.version, ready: true))
            }
        case .idle:
            // Ya instalada: la app corre esa versión (o una más nueva).
            if let notified = defaults.string(forKey: Key.dispatch),
               !PluginUpdates.isNewer(notified, than: AppUpdater.currentVersion) {
                settle(.dispatch)
            }
        case .checking, .downloading, .installing:
            break
        }

        if let latest = status.latestVersion {
            offer(.paperclip, version: latest, key: Key.paperclip, enabled: enabled) {
                (Self.paperclipNotice(latest), Self.paperclipItem(latest))
            }
        } else if status.paperclipVersion != nil || status.updatesUnavailable != nil {
            settle(.paperclip)
        }

        let pending = plugins.canUpdate ? plugins.available : []
        if !pending.isEmpty {
            offerPlugins(pending, enabled: enabled)
        } else if plugins.lastCheckedAt != nil {
            settle(.plugins)
        }
    }

    private func offer(
        _ kind: Kind, version: String, key: String, enabled: Bool, content: () -> (Notice, UpdatePill.Item)
    ) {
        guard defaults.string(forKey: key) != version else { return }
        defaults.set(version, forKey: key)
        guard enabled, !isPanelOpen(kind.panel) else { return }
        let (notice, item) = content()
        announce(kind, notice, item)
    }

    private func offerPlugins(_ pending: [PluginUpdates.Plugin], enabled: Bool) {
        var notified = defaults.dictionary(forKey: Key.plugins) as? [String: String] ?? [:]
        guard pending.contains(where: { notified[$0.id] != $0.latest }) else { return }
        if enabled, !isPanelOpen(.plugins) {
            // Si ya hubo uno hoy, espera: una revisión de más adelante (cada hora) lo avisa con todo lo nuevo.
            if let last = defaults.object(forKey: Key.pluginsAt) as? Date,
               Date.now.timeIntervalSince(last) < Self.pluginInterval {
                return
            }
            announce(.plugins, Self.pluginsNotice(pending), Self.pluginsItem(pending))
            defaults.set(Date.now, forKey: Key.pluginsAt)
        }
        for plugin in pending { notified[plugin.id] = plugin.latest }
        defaults.set(notified, forKey: Key.plugins)
    }

    /// Mirando la ventana, la píldora; afuera, el aviso de macOS, y la píldora espera a que se vuelva.
    private func announce(_ kind: Kind, _ notice: Notice, _ item: UpdatePill.Item) {
        waiting[kind] = item
        if isInFront() {
            if pill.isVisible { pill.show(waitingItems) } else { presentWhenPossible(after: .zero) }
        } else {
            notifications.show(
                id: kind.identifier, tag: kind.identifier, title: notice.title, body: notice.body, href: nil,
                opensPanel: kind.panel, sound: false
            )
            shown.insert(kind)
        }
    }

    /// Muestra la píldora en cuanto se pueda, mientras se siga mirando la ventana.
    private func presentWhenPossible(after delay: Duration) {
        guard presenting == nil, !waiting.isEmpty, !pill.isVisible else { return }
        presenting = Task { [weak self] in
            try? await Task.sleep(for: delay)
            while let self, !Task.isCancelled, !waiting.isEmpty, isInFront() {
                if canPresent() {
                    pill.show(waitingItems)
                    break
                }
                try? await Task.sleep(for: Self.retryInterval)
            }
            // Cancelada, ya la soltó quien la canceló (y puede haber otra en marcha).
            if !Task.isCancelled { self?.presenting = nil }
        }
    }

    private var waitingItems: [UpdatePill.Item] {
        waiting.sorted { $0.key < $1.key }.map(\.value)
    }

    /// Visto: se va de la píldora y de la lista de macOS.
    private func acknowledge(_ kinds: [Kind]) {
        for kind in kinds { waiting[kind] = nil }
        if waiting.isEmpty {
            presenting?.cancel()
            presenting = nil
            pill.hide()
        } else if pill.isVisible {
            pill.show(waitingItems)
        }
        for kind in kinds where shown.remove(kind) != nil {
            notifications.remove(identifier: kind.identifier)
        }
    }

    /// Ya no hay nada que actualizar de ese tipo: se quita de la píldora y de la lista de macOS.
    private func settle(_ kind: Kind) {
        if waiting.removeValue(forKey: kind) != nil, pill.isVisible {
            if waiting.isEmpty { pill.hide() } else { pill.show(waitingItems) }
        }
        guard shown.remove(kind) != nil else { return }
        notifications.remove(identifier: kind.identifier)
    }

    // MARK: - Lo que dicen (también para los ensayos)

    /// `ready`: ya se descargó y se instala al reiniciar. Si no, con las descargas automáticas apagadas.
    static func dispatchNotice(_ version: String, ready: Bool) -> Notice {
        ready
            ? Notice(
                title: String(localized: "Dispatch \(version) is ready"),
                body: String(localized: "It installs when you restart or quit the app. Paperclip and your agents keep working.")
            )
            : Notice(
                title: String(localized: "Dispatch \(version) is out"),
                body: String(localized: "Download it from the updates button whenever you like. Paperclip and your agents keep working.")
            )
    }

    static func paperclipNotice(_ version: String) -> Notice {
        Notice(
            title: String(localized: "Paperclip \(version) is out"),
            body: String(localized: "Updating it restarts it and pauses your agents in the meantime: best done at a quiet moment.")
        )
    }

    /// Todos los que tienen versión nueva, no solo los que no se habían avisado: el aviso reemplaza al anterior.
    static func pluginsNotice(_ plugins: [PluginUpdates.Plugin]) -> Notice {
        let versions = plugins.map(versionName)
        guard plugins.count > 1 else {
            return Notice(
                title: String(localized: "\(versions.first ?? "") is out"),
                body: String(localized: "A Paperclip plugin. Update it whenever you like: your agents keep working.")
            )
        }
        return Notice(
            title: String(localized: "\(plugins.count) plugins have new versions"),
            body: String(localized: "\(versions.formatted(.list(type: .and))). Update them whenever you like: your agents keep working.")
        )
    }

    static func dispatchItem(_ version: String, ready: Bool) -> UpdatePill.Item {
        UpdatePill.Item(
            kind: .dispatch,
            lead: dispatchNotice(version, ready: ready).title + ".",
            detail: ready
                ? String(localized: "It installs when you restart the app.")
                : String(localized: "Download it whenever you like."),
            short: "Dispatch \(version)"
        )
    }

    static func paperclipItem(_ version: String) -> UpdatePill.Item {
        UpdatePill.Item(
            kind: .paperclip,
            lead: paperclipNotice(version).title + ".",
            detail: String(localized: "Best updated at a quiet moment: it restarts."),
            short: "Paperclip \(version)"
        )
    }

    static func pluginsItem(_ plugins: [PluginUpdates.Plugin]) -> UpdatePill.Item {
        UpdatePill.Item(
            kind: .plugins,
            lead: pluginsNotice(plugins).title + ".",
            detail: plugins.count > 1
                ? String(localized: "Update them whenever you like.")
                : String(localized: "Update it whenever you like."),
            short: plugins.count > 1 ? String(localized: "\(plugins.count) plugins") : plugins.map(versionName).first ?? ""
        )
    }

    private static func versionName(_ plugin: PluginUpdates.Plugin) -> String {
        "\(plugin.name) \(plugin.latest ?? plugin.version)"
    }
}
