import Foundation

/// «Iniciar Paperclip al iniciar sesión» (Ajustes → Paperclip), para el Paperclip de esta Mac.
///
/// Es el servicio de launchd que instala Paperclip (`paperclipai service install`): arranca al iniciar
/// sesión, sin ventana de Terminal y aunque esta app esté cerrada, y vuelve a arrancar si se cae.
/// - Sin servicio, encenderlo lo instala con el comando oficial, que además lo enciende ya.
/// - Con servicio, solo se activa o desactiva su arranque al iniciar sesión (`launchctl enable/disable`,
///   lo mismo que hace su CLI). No lo apaga ni lo reinicia: los agentes siguen con lo que estaban haciendo.
@MainActor
@Observable
final class PaperclipStartup {
    enum State: Equatable {
        case checking
        case on
        case off
    }

    /// Lo que devuelve zsh cuando no encuentra el comando.
    private static let commandNotFound: Int32 = 127
    private static let errorTailLines = 4

    private(set) var state: State = .checking
    private(set) var busy = false
    private(set) var error: String?
    /// Hay una instalación de Paperclip en esta Mac (su configuración en `~/.paperclip`).
    private(set) var available = true

    func refresh() async {
        let local = PaperclipLocator.installed()
        available = local != nil
        guard let local, local.hasService else {
            state = .off
            return
        }
        state = await PaperclipLocator.startsAtLogin(local.instanceId) == false ? .off : .on
    }

    func set(_ enabled: Bool) {
        guard !busy, let local = PaperclipLocator.installed() else { return }
        busy = true
        error = nil
        Task {
            defer { busy = false }
            if local.hasService {
                error = await PaperclipLocator.setStartsAtLogin(enabled, instanceId: local.instanceId)
            } else if enabled {
                error = await install(local)
            }
            await refresh()
        }
    }

    /// Sin servicio todavía. Si Paperclip ya corre en una Terminal, el servicio arrancaría otro encima, con
    /// el mismo puerto y la misma base de datos: primero hay que cerrar esa ventana.
    private func install(_ local: LocalPaperclip) async -> String? {
        if case .success = await PaperclipLocator.probe(local.url) {
            return String(localized: "Paperclip is running in a Terminal window. Close that window and turn this on again: from then on it runs in the background.")
        }
        let result = await PaperclipLocator.installService(local.instanceId)
        if result.status == Self.commandNotFound {
            return String(localized: "This needs the Paperclip command. Install it with \(UpdateController.installCLICommand) and try again.")
        }
        guard result.status == 0 else { return result.tail(Self.errorTailLines) }
        return nil
    }
}
