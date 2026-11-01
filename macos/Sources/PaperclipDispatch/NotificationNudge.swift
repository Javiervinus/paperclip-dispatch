import Foundation
import Observation

/// El recordatorio de avisos: una píldora abajo, sobre la página, si los avisos están apagados o a medias
/// (sin banner o sin el número en el Dock) y en Ajustes → Avisos se quiere lo que falta. Sale unos segundos
/// después de entrar a Paperclip, o al cerrar una sugerencia, nunca con una hoja abierta. Con × se esconde
/// una semana; después de tres veces no vuelve.
@MainActor
@Observable
final class NotificationNudge {
    enum Problem: Equatable {
        /// Sin permiso: nunca se pidió o se negó.
        case off
        /// Solo llegan al Centro de notificaciones.
        case noBanners
        /// macOS no deja poner el número en el Dock.
        case noBadge
    }

    private static let snoozedUntilKey = "notificationNudgeSnoozedUntil"
    private static let dismissalsKey = "notificationNudgeDismissals"
    private static let maximumDismissals = 3
    private static let snooze: TimeInterval = 7 * 24 * 60 * 60
    private static let delayAfterSignIn: Duration = .seconds(8)
    private static let delayAfterSheet: Duration = .milliseconds(900)
    /// Lo que se ve «Avisos activados» antes de irse.
    private static let confirmationTime: Duration = .seconds(2.2)

    private(set) var problem: Problem?
    private(set) var isVisible = false
    /// Se arregló con la píldora a la vista: lo confirma un momento y se va.
    private(set) var confirmed = false
    /// El aviso de permiso de macOS está a la vista, esperando la respuesta.
    private(set) var waitingForAnswer = false

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let preferences: Preferences
    @ObservationIgnored private let notifications: NotificationBridge
    /// Si se puede mostrar ahora: la ventana al frente, sin hojas ni la vista sin conexión.
    @ObservationIgnored private let canPresent: () -> Bool
    @ObservationIgnored private var access: NotificationAccess?
    @ObservationIgnored private var pending: Task<Void, Never>?
    /// Una vez por apertura de la app: si se va (arreglado o con ×), no vuelve hasta la próxima.
    @ObservationIgnored private var shownThisLaunch = false

    init(
        preferences: Preferences,
        notifications: NotificationBridge,
        defaults: UserDefaults = .standard,
        canPresent: @escaping () -> Bool
    ) {
        self.preferences = preferences
        self.notifications = notifications
        self.defaults = defaults
        self.canPresent = canPresent
    }

    /// Para el ensayo: la píldora ya a la vista con ese problema.
    init(previewing problem: Problem, preferences: Preferences, notifications: NotificationBridge) {
        self.preferences = preferences
        self.notifications = notifications
        defaults = UserDefaults(suiteName: "NotificationNudgePreview") ?? .standard
        canPresent = { false }
        self.problem = problem
        isVisible = true
    }

    /// Después de cada revisión con sesión en Paperclip.
    func signedIn() { schedule(after: Self.delayAfterSignIn) }

    /// Se cerró una sugerencia: si hace falta, la píldora sale enseguida.
    func sheetClosed() {
        pending?.cancel()
        pending = nil
        schedule(after: Self.delayAfterSheet)
    }

    /// El permiso o los ajustes de avisos cambiaron (también en Ajustes del Sistema).
    func update(_ access: NotificationAccess) {
        self.access = access
        guard isVisible, !confirmed else { return }
        if let problem = currentProblem() {
            self.problem = problem
        } else {
            confirm()
        }
    }

    /// Cambió Ajustes → Avisos: si ya no se quiere lo que faltaba, se va sin confirmar nada.
    func preferencesChanged() {
        guard isVisible, !confirmed else { return }
        if let problem = currentProblem() {
            self.problem = problem
        } else {
            isVisible = false
        }
    }

    /// «Activar» pide el permiso si nunca se pidió; si no, abre Ajustes del Sistema en la página de la app.
    func act() {
        if problem == .off, access?.permission == .notDetermined {
            waitingForAnswer = true
            Task {
                _ = await notifications.request()
                waitingForAnswer = false
            }
        } else {
            NotificationAccess.openSystemSettings()
        }
    }

    /// La ×: una semana sin recordatorio.
    func dismiss() {
        defaults.set(Date.now.addingTimeInterval(Self.snooze), forKey: Self.snoozedUntilKey)
        defaults.set(defaults.integer(forKey: Self.dismissalsKey) + 1, forKey: Self.dismissalsKey)
        isVisible = false
    }

    private func schedule(after delay: Duration) {
        guard pending == nil, !shownThisLaunch, isAllowed, currentProblem() != nil else { return }
        pending = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            pending = nil
            // Si ahora no se puede (otra app al frente, una hoja), se intenta en la revisión siguiente.
            guard canPresent(), let problem = currentProblem() else { return }
            self.problem = problem
            confirmed = false
            shownThisLaunch = true
            isVisible = true
        }
    }

    private var isAllowed: Bool {
        if defaults.integer(forKey: Self.dismissalsKey) >= Self.maximumDismissals { return false }
        if let until = defaults.object(forKey: Self.snoozedUntilKey) as? Date, until > .now { return false }
        return true
    }

    /// Lo que falta de lo que se quiere: los banners solo importan con los avisos de Decisions encendidos, y
    /// el número solo con el del Dock.
    private func currentProblem() -> Problem? {
        guard let access else { return nil }
        let wantsAlerts = preferences.decisionNotifications
        let wantsBadge = preferences.dockBadge
        if access.permission != .granted { return wantsAlerts || wantsBadge ? .off : nil }
        if wantsAlerts, !access.banners { return .noBanners }
        if wantsBadge, !access.badge { return .noBadge }
        return nil
    }

    private func confirm() {
        confirmed = true
        Task { [weak self] in
            try? await Task.sleep(for: Self.confirmationTime)
            self?.isVisible = false
        }
    }
}
