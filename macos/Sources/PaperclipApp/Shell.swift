import Foundation

/// Comandos con el shell de inicio de Javier (`zsh -l`), que trae el PATH de paperclipai, node y python.
enum Shell {
    struct Result: Sendable {
        let status: Int32
        let output: String

        /// Las últimas líneas, para mostrar un error sin todo el registro.
        func tail(_ count: Int) -> String {
            output.split(separator: "\n", omittingEmptySubsequences: true).suffix(count).joined(separator: "\n")
        }
    }

    /// `arguments` va después de `zsh -l`: ["-c", "comando"] o [ruta del script].
    /// `timeout`: si pasa, el proceso se corta. `onLine` recibe cada línea de la salida mientras corre.
    static func run(
        _ arguments: [String],
        timeout: TimeInterval? = nil,
        onLine: (@Sendable (String) -> Void)? = nil
    ) async -> Result {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-l"] + arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            let output = OutputCollector(onLine: onLine)
            pipe.fileHandleForReading.readabilityHandler = { handle in
                output.append(handle.availableData)
            }
            process.terminationHandler = { process in
                pipe.fileHandleForReading.readabilityHandler = nil
                output.append(pipe.fileHandleForReading.readDataToEndOfFile())
                output.finish()
                continuation.resume(returning: Result(status: process.terminationStatus, output: output.text))
            }
            do {
                try process.run()
                if let timeout {
                    let running = RunningProcess(process)
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { running.terminate() }
                }
            } catch {
                continuation.resume(returning: Result(status: -1, output: error.localizedDescription))
            }
        }
    }
}

/// Para cortar un proceso desde otro hilo cuando se pasa del tiempo.
private final class RunningProcess: @unchecked Sendable {
    private let process: Process

    init(_ process: Process) {
        self.process = process
    }

    func terminate() {
        if process.isRunning { process.terminate() }
    }
}

/// Junta la salida de un proceso desde los hilos de Foundation y la entrega por líneas.
private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var partialLine = ""
    private let onLine: (@Sendable (String) -> Void)?

    init(onLine: (@Sendable (String) -> Void)?) {
        self.onLine = onLine
    }

    var text: String {
        lock.withLock { String(decoding: data, as: UTF8.self) }
    }

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        let lines: [String] = lock.withLock {
            data.append(chunk)
            partialLine += String(decoding: chunk, as: UTF8.self)
            var parts = partialLine.components(separatedBy: "\n")
            partialLine = parts.removeLast()
            return parts
        }
        lines.forEach { onLine?($0) }
    }

    func finish() {
        let last: String = lock.withLock {
            defer { partialLine = "" }
            return partialLine
        }
        if !last.isEmpty { onLine?(last) }
    }
}
