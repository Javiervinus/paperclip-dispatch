import Foundation

/// Una revisión del diagnóstico de Paperclip: «✓ Database: Embedded PostgreSQL configured…».
struct DoctorCheck: Identifiable, Equatable, Sendable {
    enum Status: Sendable { case passed, warning, failed }

    let status: Status
    /// Lo que revisa, en inglés como lo escribe Paperclip («Database», «Server port»).
    let name: String
    let message: String
    /// El comando o el paso que sugiere Paperclip para arreglarlo.
    let hint: String?

    var id: String { name }
}

/// El diagnóstico oficial de Paperclip, `paperclipai doctor`, el mismo que corre `paperclipai run` antes de
/// arrancar: configuración, base de datos, puerto, Node.js, la instalación del comando y el servicio. Sin
/// `--repair` solo lee. No tiene salida JSON, así que se lee su texto, que Paperclip escribe así:
///
///     │  ✗ Service version: Running unknown; managed install is 2026.1106.0
///     │
///     │    Run `paperclipai service restart --expected-version 2026.1106.0`
enum PaperclipDoctor {
    enum Outcome: Equatable, Sendable {
        case checks([DoctorCheck])
        /// Falta el comando `paperclipai`.
        case unavailable
        /// Corrió, pero no se entendió lo que escribió: las últimas líneas.
        case unreadable(String)
    }

    /// Lo que devuelve zsh cuando no encuentra el comando.
    private static let commandNotFound: Int32 = 127
    private static let unreadableTailLines = 6
    /// El marco que dibuja Paperclip a la izquierda de cada línea.
    private static let frame: Set<Character> = ["│", " "]

    /// `repair`: además arregla lo que sabe arreglar (`--repair --yes`), sin preguntar.
    static func run(instanceId: String, repair: Bool) async -> Outcome {
        let instance = "PAPERCLIP_INSTANCE_ID='\(instanceId.replacingOccurrences(of: "'", with: "'\\''"))'"
        let result = await Shell.run(["-c", "\(instance) paperclipai doctor\(repair ? " --repair --yes" : "") </dev/null"])
        if result.status == commandNotFound { return .unavailable }
        let checks = parse(result.output)
        return checks.isEmpty ? .unreadable(result.tail(unreadableTailLines)) : .checks(checks)
    }

    static func parse(_ output: String) -> [DoctorCheck] {
        var checks: [DoctorCheck] = []
        var waitingForHint = false
        for raw in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw).replacing(#/\e\[[0-9;?]*[A-Za-z]/#, with: "")
            // Solo lo que va dentro del marco («│ …»): los avisos de reparar («◆ Repaired: …») y el resumen
            // («◇ Summary») son otra cosa.
            guard line.hasPrefix("│") else {
                waitingForHint = false
                continue
            }
            let text = String(line.drop(while: { frame.contains($0) }))
            guard !text.isEmpty else { continue }
            if let match = text.wholeMatch(of: #/(✓|!|✗) ([^:]+): (.*)/#) {
                let status: DoctorCheck.Status = switch match.1 {
                case "✓": .passed
                case "!": .warning
                default: .failed
                }
                // Al reparar, Paperclip vuelve a escribir la revisión: vale la última.
                checks.removeAll { $0.name == String(match.2) }
                checks.append(DoctorCheck(status: status, name: String(match.2), message: String(match.3), hint: nil))
                waitingForHint = status != .passed
            } else if waitingForHint, let last = checks.popLast() {
                checks.append(DoctorCheck(status: last.status, name: last.name, message: last.message, hint: text))
                waitingForHint = false
            }
        }
        return checks
    }

    /// Lo que no pasó, sin las falsas alarmas conocidas:
    /// - «Server port … in use» con Paperclip respondiendo: el puerto lo ocupa el propio Paperclip.
    /// - «Service version: Running unknown»: en modo `authenticated`, `/api/health` no dice la versión
    ///   (paperclipai/paperclip#13697), así que el doctor nunca la ve.
    static func problems(in checks: [DoctorCheck], paperclipRunning: Bool) -> [DoctorCheck] {
        checks.filter { check in
            guard check.status != .passed else { return false }
            if paperclipRunning, check.name == "Server port" { return false }
            if check.name == "Service version", check.message.hasPrefix("Running unknown") { return false }
            return true
        }
    }
}

/// El diagnóstico para mostrar: en Ajustes → Paperclip y en la ventana cuando Paperclip no arranca.
@MainActor
@Observable
final class DoctorModel {
    enum State: Equatable {
        case idle
        case running(repairing: Bool)
        /// Lo que no pasó, ya sin falsas alarmas.
        case done(problems: [DoctorCheck])
        case unavailable
        case unreadable(String)
    }

    private(set) var state: State = .idle

    var isRunning: Bool {
        if case .running = state { true } else { false }
    }

    func run(repair: Bool = false) {
        guard !isRunning, let local = PaperclipLocator.installed() else { return }
        state = .running(repairing: repair)
        Task {
            let outcome = await PaperclipDoctor.run(instanceId: local.instanceId, repair: repair)
            switch outcome {
            case let .checks(checks):
                let running = if case .success = await PaperclipLocator.probe(local.url) { true } else { false }
                state = .done(problems: PaperclipDoctor.problems(in: checks, paperclipRunning: running))
            case .unavailable:
                state = .unavailable
            case let .unreadable(tail):
                state = .unreadable(tail)
            }
        }
    }

    func reset() {
        guard !isRunning else { return }
        state = .idle
    }
}
