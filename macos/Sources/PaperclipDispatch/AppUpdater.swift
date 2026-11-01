import AppKit
import Observation
import Sparkle

/// Las versiones nuevas de la propia app (Paperclip Dispatch), con Sparkle y una interfaz propia: el botón
/// de arriba a la derecha y Ajustes, en vez de las ventanas de Sparkle.
///
/// Busca sola cada tantas horas y, si está activado (por defecto), descarga en silencio. Nunca se reinicia
/// sin permiso: la versión descargada se instala cuando la persona aprieta «Reiniciar» o cuando cierra la
/// app (Cmd+Q, apagar la Mac). Paperclip y sus agentes no se enteran, porque corren aparte.
///
/// Sparkle lee de Info.plist la dirección del appcast (`SUFeedURL`) y la llave para verificar la firma
/// (`SUPublicEDKey`); sin ellas, la app no busca versiones (un build de prueba, por ejemplo).
@MainActor
@Observable
final class AppUpdater: NSObject {
    /// Una versión publicada, como la describe el appcast.
    struct Release: Equatable, Codable {
        let version: String
        /// Las novedades en Markdown. El appcast las trae en inglés y en español, y Sparkle elige las del
        /// idioma de la app.
        let notes: String?
        /// La página de la versión en GitHub, con las novedades completas.
        let notesURL: URL?
    }

    enum Phase: Equatable {
        case idle
        /// Una búsqueda pedida a mano (las automáticas no se muestran).
        case checking
        /// Hay versión nueva y no está descargada: con las descargas automáticas apagadas.
        case available(Release)
        case downloading(Release, progress: Double?)
        /// Descargada: se instala al reiniciar o al cerrar la app.
        case ready(Release)
        case installing(Release)

        var release: Release? {
            switch self {
            case .idle, .checking: nil
            case .available(let release), .downloading(let release, _), .ready(let release), .installing(let release):
                release
            }
        }
    }

    static let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    /// Cuántos días se ofrecen las novedades de la versión recién instalada, si no se abren antes.
    private static let whatsNewDays = 3
    private static let whatsNewKey = "dispatchWhatsNew"
    private static let whatsNewUntilKey = "dispatchWhatsNewUntil"
    /// Para probar con un appcast local sin rearmar la app: `defaults write <id> DispatchFeedURL <url>`.
    private static let feedOverrideKey = "DispatchFeedURL"
    /// La página que estaba abierta al reiniciar para actualizar: la app vuelve a ella.
    private static let restorePageKey = "dispatchRestorePage"

    private(set) var phase: Phase = .idle
    private(set) var lastCheckedAt: Date?
    /// Por qué falló la última búsqueda pedida a mano.
    private(set) var checkError: String?
    /// Lo que trajo la versión recién instalada, hasta que se mira o pasan unos días.
    private(set) var whatsNew: Release?
    /// Si este build sabe dónde buscar versiones (appcast y llave en Info.plist).
    let isConfigured: Bool

    /// Descargar en silencio las versiones nuevas. Sparkle lo guarda en sus ajustes (`SUAutomaticallyUpdate`).
    var automaticallyDownloads = true {
        didSet {
            guard let updater, updater.automaticallyDownloadsUpdates != automaticallyDownloads else { return }
            updater.automaticallyDownloadsUpdates = automaticallyDownloads
        }
    }

    /// Antes de reiniciar para instalar: la app guarda lo que necesita (la página abierta).
    @ObservationIgnored var willRelaunch: (() -> Void)?
    /// Sparkle pide mostrar la versión (p. ej. al abrir la app otra vez desde el Dock durante una descarga).
    @ObservationIgnored var onShowRequested: (() -> Void)?

    @ObservationIgnored private var updater: SPUUpdater?
    /// La respuesta que Sparkle espera cuando mostró una versión: instalar, descartar u omitir.
    @ObservationIgnored private var pendingChoice: ((SPUUserUpdateChoice) -> Void)?
    /// Instala ya la versión descargada en silencio y vuelve a abrir la app.
    @ObservationIgnored private var installNow: (() -> Void)?
    /// Se apretó «Reiniciar» (o «Descargar y reiniciar»): al terminar la descarga se instala sin preguntar.
    @ObservationIgnored private var installRequested = false
    @ObservationIgnored private var expectedLength: UInt64 = 0
    @ObservationIgnored private var receivedLength: UInt64 = 0
    @ObservationIgnored private var userInitiated = false
    /// Las novedades ya guardadas para el próximo arranque (para no reescribirlas en cada aviso de Sparkle).
    @ObservationIgnored private var savedWhatsNew: Release?

    /// Para los ensayos: en ese estado, sin Sparkle. «Reiniciar» no hace nada.
    init(previewing phase: Phase, whatsNew: Release? = nil) {
        isConfigured = true
        super.init()
        self.phase = phase
        self.whatsNew = whatsNew
        lastCheckedAt = .now
    }

    override init() {
        let info = Bundle.main.infoDictionary ?? [:]
        let feed = UserDefaults.standard.string(forKey: Self.feedOverrideKey) ?? info["SUFeedURL"] as? String
        let key = info["SUPublicEDKey"] as? String
        isConfigured = feed?.isEmpty == false && key?.isEmpty == false
        super.init()
        whatsNew = Self.loadWhatsNew()
    }

    /// Arranca las búsquedas automáticas. No se llama en los ensayos.
    func start() {
        guard isConfigured, updater == nil else { return }
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: self, delegate: self)
        do {
            try updater.start()
        } catch {
            NSLog("Paperclip Dispatch: couldn't start updates: %@", error.localizedDescription)
            return
        }
        self.updater = updater
        automaticallyDownloads = updater.automaticallyDownloadsUpdates
        lastCheckedAt = updater.lastUpdateCheckDate
    }

    /// Desde el panel, Ajustes o el menú. Si ya hay una versión esperando, no hace falta buscar.
    func checkNow() {
        guard let updater, updater.canCheckForUpdates else { return }
        checkError = nil
        updater.checkForUpdates()
    }

    /// «Reiniciar» o «Descargar y reiniciar»: lo único que reinicia la app.
    func install() {
        guard let release = phase.release else { return }
        if savedWhatsNew != release {
            Self.saveWhatsNew(release)
            savedWhatsNew = release
        }
        installRequested = true
        if let installNow {
            phase = .installing(release)
            willRelaunch?()
            installNow()
        } else if let reply = pendingChoice {
            pendingChoice = nil
            if case .available = phase {
                phase = .downloading(release, progress: nil)
            } else {
                phase = .installing(release)
                willRelaunch?()
            }
            reply(.install)
        }
    }

    func dismissWhatsNew() {
        whatsNew = nil
        // Lo guardado ya es de la versión que viene (lista para instalar): esas se quedan.
        guard savedWhatsNew == nil else { return }
        UserDefaults.standard.removeObject(forKey: Self.whatsNewKey)
        UserDefaults.standard.removeObject(forKey: Self.whatsNewUntilKey)
    }

    // MARK: - La página al reiniciar

    static func rememberPage(_ url: URL?) {
        UserDefaults.standard.set(url?.absoluteString, forKey: restorePageKey)
    }

    /// La página guardada antes de reiniciar, si es del mismo Paperclip. Se usa una sola vez.
    static func takeRememberedPage(on server: URL) -> URL? {
        defer { UserDefaults.standard.removeObject(forKey: restorePageKey) }
        guard let string = UserDefaults.standard.string(forKey: restorePageKey), let url = URL(string: string),
              url.host() == server.host(), url.port == server.port
        else { return nil }
        return url
    }

    // MARK: - Novedades de la versión instalada

    private static func saveWhatsNew(_ release: Release) {
        guard let data = try? JSONEncoder().encode(release) else { return }
        UserDefaults.standard.set(data, forKey: whatsNewKey)
        UserDefaults.standard.removeObject(forKey: whatsNewUntilKey)
    }

    /// Las de la versión que corre ahora, si se instaló hace poco. El plazo empieza al primer arranque.
    private static func loadWhatsNew() -> Release? {
        let defaults = UserDefaults.standard
        guard let data = defaults.data(forKey: whatsNewKey),
              let release = try? JSONDecoder().decode(Release.self, from: data),
              release.version == currentVersion
        else {
            defaults.removeObject(forKey: whatsNewKey)
            defaults.removeObject(forKey: whatsNewUntilKey)
            return nil
        }
        guard let until = defaults.object(forKey: whatsNewUntilKey) as? Date else {
            let until = Calendar.current.date(byAdding: .day, value: whatsNewDays, to: .now) ?? .now
            defaults.set(until, forKey: whatsNewUntilKey)
            return release
        }
        return until > .now ? release : nil
    }

    /// Lista para instalar: se guardan ya sus novedades, porque también se instala sola al cerrar la app y
    /// en el próximo arranque tienen que estar (si no se instaló, la versión no coincide y se descartan).
    private func setReady(_ release: Release) {
        if savedWhatsNew != release {
            Self.saveWhatsNew(release)
            savedWhatsNew = release
        }
        phase = .ready(release)
        lastCheckedAt = updater?.lastUpdateCheckDate ?? .now
    }
}

extension AppUpdater.Release {
    init(_ item: SUAppcastItem) {
        version = item.displayVersionString
        // El appcast las trae en Markdown; si alguna vez vinieran en HTML, mejor el enlace que etiquetas.
        notes = item.itemDescriptionFormat == "html" ? nil : item.itemDescription
        notesURL = item.fullReleaseNotesURL ?? item.infoURL ?? item.releaseNotesURL
    }
}

// MARK: - Lo que Sparkle muestra

extension AppUpdater: SPUUserDriver {
    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        // Info.plist ya activa las búsquedas (SUEnableAutomaticChecks): esto no debería llegar.
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        userInitiated = true
        phase = .checking
    }

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        userInitiated = false
        let release = AppUpdater.Release(appcastItem)
        // Solo informativa (sin archivo): no hay nada que instalar desde aquí.
        guard !appcastItem.isInformationOnlyUpdate else {
            reply(.dismiss)
            phase = .idle
            return
        }
        pendingChoice = reply
        switch state.stage {
        case .downloaded, .installing: setReady(release)
        default: phase = .available(release)
        }
        lastCheckedAt = .now
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {}

    func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        userInitiated = false
        phase = .idle
        checkError = nil
        lastCheckedAt = .now
        acknowledgement()
    }

    func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        if userInitiated || installRequested {
            checkError = error.localizedDescription
        }
        userInitiated = false
        installRequested = false
        if let release = phase.release, installNow != nil {
            phase = .ready(release)
        } else {
            phase = .idle
        }
        acknowledgement()
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        expectedLength = 0
        receivedLength = 0
        if let release = phase.release { phase = .downloading(release, progress: nil) }
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        expectedLength = expectedContentLength
        receivedLength = 0
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        receivedLength += length
        guard expectedLength > 0, let release = phase.release else { return }
        phase = .downloading(release, progress: min(Double(receivedLength) / Double(expectedLength), 1))
    }

    func showDownloadDidStartExtractingUpdate() {
        if let release = phase.release { phase = .downloading(release, progress: nil) }
    }

    func showExtractionReceivedProgress(_ progress: Double) {}

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        guard let release = phase.release else {
            reply(.dismiss)
            return
        }
        if installRequested {
            phase = .installing(release)
            willRelaunch?()
            reply(.install)
        } else {
            pendingChoice = reply
            setReady(release)
        }
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        if let release = phase.release { phase = .installing(release) }
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        acknowledgement()
    }

    func showUpdateInFocus() {
        onShowRequested?()
    }

    func dismissUpdateInstallation() {
        userInitiated = false
        switch phase {
        case .ready where installNow != nil || pendingChoice != nil, .installing:
            break
        case .checking, .downloading, .available, .ready:
            if pendingChoice == nil { phase = .idle }
        case .idle:
            break
        }
    }
}

// MARK: - Cuándo instalar

extension AppUpdater: SPUUpdaterDelegate {
    /// La versión se descargó sola. Se toma el control: no se instala hasta que la persona aprieta
    /// «Reiniciar». Sparkle igual la instala cuando la app se cierra.
    func updater(
        _ updater: SPUUpdater,
        willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
    ) -> Bool {
        installNow = immediateInstallHandler
        setReady(AppUpdater.Release(item))
        return true
    }

    func feedURLString(for updater: SPUUpdater) -> String? {
        UserDefaults.standard.string(forKey: AppUpdater.feedOverrideKey)
    }

    func updater(_ updater: SPUUpdater, shouldDownloadReleaseNotesForUpdate updateItem: SUAppcastItem) -> Bool {
        false
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        if let date = updater.lastUpdateCheckDate { lastCheckedAt = date }
    }

    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        willRelaunch?()
    }
}
