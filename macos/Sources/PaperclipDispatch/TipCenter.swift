import AppKit

/// Decide cuándo sale una sugerencia (`Tip`) y la muestra como hoja de la ventana de Paperclip. Sale una vez
/// cada una y como mucho una al día, unos segundos después de una revisión con la sesión iniciada (nunca a
/// media carga ni en la pantalla de inicio), y solo si se está mirando la ventana sin nada encima.
@MainActor
final class TipCenter {
    private static let shownKey = "tipsShown"
    private static let lastShownKey = "tipLastShownAt"
    /// Lo que se espera después de entrar a Paperclip, para no tapar lo primero que se ve.
    private static let delay: Duration = .seconds(4)
    private static let minimumGap: TimeInterval = 24 * 60 * 60

    private let defaults: UserDefaults
    private weak var host: MainWindowController?
    /// Si la sugerencia todavía sirve (p. ej., la de Telegram, si no hay bot).
    private let isRelevant: (Tip) -> Bool
    private var pending: Task<Void, Never>?
    private var sheet: NSWindow?

    /// El botón principal de la sugerencia («Configurar Telegram»).
    var onAction: ((Tip) -> Void)?
    /// La hoja se cerró, con cualquiera de los dos botones.
    var onClose: (() -> Void)?

    init(host: MainWindowController, defaults: UserDefaults = .standard, isRelevant: @escaping (Tip) -> Bool) {
        self.host = host
        self.defaults = defaults
        self.isRelevant = isRelevant
    }

    /// Después de cada revisión con sesión: si toca una sugerencia, se agenda. Si al llegar el momento no se
    /// puede mostrar (otra app al frente, una hoja abierta), se vuelve a intentar en la revisión siguiente.
    func signedIn() {
        guard pending == nil, sheet == nil, nextTip() != nil else { return }
        pending = Task { [weak self] in
            try? await Task.sleep(for: Self.delay)
            guard let self, !Task.isCancelled else { return }
            pending = nil
            guard let host, host.canPresentOverlay, let tip = nextTip() else { return }
            show(tip, on: host)
        }
    }

    /// La primera que no salió y todavía sirve, si ya pasó un día desde la última.
    private func nextTip() -> Tip? {
        if let last = defaults.object(forKey: Self.lastShownKey) as? Date,
           Date.now.timeIntervalSince(last) < Self.minimumGap {
            return nil
        }
        let shown = Set(defaults.stringArray(forKey: Self.shownKey) ?? [])
        return Tip.allCases.first { !shown.contains($0.rawValue) && isRelevant($0) }
    }

    private func show(_ tip: Tip, on host: MainWindowController) {
        // Cuenta como vista al aparecer: «Ahora no» tampoco la hace volver.
        defaults.set((defaults.stringArray(forKey: Self.shownKey) ?? []) + [tip.rawValue], forKey: Self.shownKey)
        defaults.set(Date.now, forKey: Self.lastShownKey)
        let view = TipSheetView(
            tip: tip,
            onAction: { [weak self] in
                self?.close()
                self?.onAction?(tip)
            },
            onDismiss: { [weak self] in self?.close() }
        )
        sheet = host.presentSheet(view)
    }

    private func close() {
        guard let sheet else { return }
        self.sheet = nil
        host?.dismissSheet(sheet)
        onClose?()
    }
}
