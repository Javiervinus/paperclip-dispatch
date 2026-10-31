import Foundation

/// Explica una decisión con el contexto de su tarea, para entenderla antes de contestar: de qué trata,
/// qué hizo el agente, qué pide y qué pasa con cada opción.
///
/// No es un agente ni conversa: una explicación por decisión, sin herramientas, sin decidir ni escribir en
/// Paperclip, y solo con lo que se le pasa (la tarea, el resumen del agente, los últimos comentarios y la
/// decisión). Para preguntar está el agente de la tarea, o el agente propio del usuario con su canal.
///
/// Usa un CLI de la Mac (los mismos con los que corren los agentes de Paperclip), con la cuenta del usuario.
/// El esfuerzo va bajo, porque resumir no pide pensar mucho y así tarda unos segundos.
@MainActor
struct DecisionExplainer {
    /// Con qué se explica. Los CLIs son los de los adaptadores de Paperclip que se probaron; para otro,
    /// «Otro comando».
    enum Engine: String, Codable, CaseIterable, Identifiable {
        case automatic, claude, codex, opencode, custom

        static let clis: [Engine] = [.claude, .codex, .opencode]

        var id: Self { self }

        /// Un valor guardado que ya no exista (p. ej. de una versión anterior) vuelve a «Automático».
        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Engine(rawValue: raw) ?? .automatic
        }

        var title: String {
            switch self {
            case .automatic: "Automático"
            case .claude: "Claude Code"
            case .codex: "Codex"
            case .opencode: "OpenCode"
            case .custom: "Otro comando…"
            }
        }

        /// El `adapterType` de los agentes de Paperclip que corren con este CLI.
        var adapterType: String? {
            switch self {
            case .claude: "claude_local"
            case .codex: "codex_local"
            case .opencode: "opencode_local"
            case .automatic, .custom: nil
            }
        }

        /// Las formas de llamarlo, de la preferida a la de respaldo (sin el esfuerzo bajo, por si un modelo o
        /// una versión no lo acepta). `$2` es el archivo con el texto, `$3` donde queda la respuesta y `$5` el
        /// modelo, si se eligió uno.
        func commands(model: Bool, custom: String?) -> [String] {
            switch self {
            case .claude:
                // Sin herramientas ni MCP: el contexto viene de las tareas y no tiene por qué mandar nada.
                let base = "claude -p --tools '' --strict-mcp-config --no-session-persistence" +
                    (model ? " --model \"$5\"" : "")
                return ["\(base) --effort low < \"$2\" > \"$3\"", "\(base) < \"$2\" > \"$3\""]
            case .codex:
                // Solo lectura y sin guardar la sesión; la respuesta final queda en el archivo.
                let base = "codex exec --skip-git-repo-check --ephemeral --sandbox read-only --color never" +
                    (model ? " -m \"$5\"" : "")
                return [
                    "\(base) -c model_reasoning_effort=\"low\" -o \"$3\" - < \"$2\" > /dev/null",
                    "\(base) -o \"$3\" - < \"$2\" > /dev/null",
                ]
            case .opencode:
                // El agente «plan» no edita archivos. Sin la entrada cerrada, OpenCode se queda esperándola.
                let base = "opencode run --agent plan" + (model ? " -m \"$5\"" : "")
                return ["\(base) \"$(cat \"$2\")\" < /dev/null > \"$3\""]
            case .custom:
                // El que elija el usuario: recibe el texto por la entrada y contesta por la salida.
                guard let custom, !custom.isEmpty else { return [] }
                return ["{ \(custom) ; } < \"$2\" > \"$3\""]
            case .automatic:
                return []
            }
        }
    }

    struct Model: Identifiable, Hashable {
        let id: String
        let title: String
    }

    /// Lo que hay en esta Mac, para mostrarlo en Ajustes.
    struct Detection: Equatable {
        var installed: [Engine]
        /// El que usa «Automático»: el que más usan los agentes de Paperclip, entre los instalados.
        var automatic: Engine?
    }

    /// Lo que tarda una explicación normal es unos 10 s; más que esto es que algo se trabó.
    private static let timeout: TimeInterval = 120
    private static let descriptionLimit = 1500
    private static let summaryLimit = 3000
    private static let commentLimit = 700
    private static let commentCount = 6
    private static let detectionLifetime: TimeInterval = 10 * 60

    /// El PATH de la terminal del usuario. Una app abierta desde el Dock no lo hereda, y `zsh -l` solo no
    /// trae lo que se carga en `.zshrc` (p. ej. nvm, donde suele quedar OpenCode).
    private static var userPath: String?
    private static var detection: (value: Detection, at: Date)?
    private static var models: [Engine: [Model]] = [:]

    let api: PaperclipAPI

    // MARK: - Contexto

    /// La tarea leída de Paperclip ahora mismo, más la decisión (`brief`), como texto para el modelo.
    func context(issueId: String?, brief: String) async -> String {
        var parts: [String] = []
        if let issueId {
            if let task: TaskContext = try? await api.get("api/issues/\(issueId)/heartbeat-context") {
                var header = "Tarea: \([task.issue.identifier, task.issue.title].compactMap { $0 }.joined(separator: " — "))"
                if let project = task.project?.name { header += " (proyecto \(project))" }
                if let status = task.issue.status { header += ", estado \(status)" }
                parts.append(header)
                if let description = task.issue.description, !description.isEmpty {
                    parts.append("Descripción:\n" + description.prefix(Self.descriptionLimit))
                }
                if let summary = task.continuationSummary?.body, !summary.isEmpty {
                    parts.append("Resumen que va llevando el agente:\n" + summary.prefix(Self.summaryLimit))
                }
            }
            let comments: [Comment]? = try? await api.get(
                "api/issues/\(issueId)/comments",
                query: [
                    URLQueryItem(name: "limit", value: String(Self.commentCount)),
                    URLQueryItem(name: "order", value: "desc"),
                ]
            )
            if let comments, !comments.isEmpty {
                parts.append("Últimos comentarios, del más viejo al más nuevo:")
                for comment in comments.reversed() {
                    let author = comment.authorType == "user" ? "Persona" : "Agente"
                    parts.append("[\(author)] " + (comment.body ?? "").prefix(Self.commentLimit))
                }
            }
        }
        parts.append("La decisión que le piden ahora:\n" + brief)
        return parts.joined(separator: "\n\n")
    }

    // MARK: - Explicar

    /// `engine` ya resuelto (ver `resolve`); `model` vacío o `nil` es el que el CLI tenga por defecto.
    func explain(context: String, engine: Engine, model: String?, customCommand: String?) async throws -> String {
        var prompt = """
        Un agente de Paperclip le pide una decisión a la persona que lo dirige, que la está viendo en el \
        teléfono. Con el contexto de abajo, explícale en español claro y en 4 a 6 líneas cortas: de qué \
        trata la tarea, qué hizo el agente hasta ahora, qué le pide exactamente y qué pasa con cada opción. \
        No decidas por ella ni inventes nada que no esté en el contexto. Solo texto, con **negritas** como \
        mucho; sin títulos ni listas largas.
        """
        prompt += "\n\n<contexto>\n\(context)\n</contexto>"

        let model = model.flatMap { $0.isEmpty ? nil : $0 }
        let commands = engine.commands(model: model != nil, custom: customCommand)
        var failure: Error = engine == .custom ? ExplainError.noCommand : ExplainError.noEngine
        for command in commands {
            do {
                return try await run(prompt, command: command, model: model)
            } catch {
                failure = error
            }
        }
        throw failure
    }

    enum ExplainError: LocalizedError {
        case noEngine
        case noCommand
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .noEngine:
                "No encontré un CLI para explicarla en esta Mac (Claude Code, Codex u OpenCode). Se elige en Ajustes → Telegram."
            case .noCommand:
                "Falta el comando en Ajustes → Telegram → «Otro comando…»."
            case let .failed(detail):
                "No pude armar la explicación: \(detail)"
            }
        }
    }

    // MARK: - Qué hay en la Mac

    /// «Automático» queda en el CLI detectado; los demás, tal cual.
    func resolve(_ engine: Engine) async -> Engine? {
        guard engine == .automatic else { return engine }
        return await detect().automatic
    }

    /// Los CLIs instalados y el que elige «Automático»: el que más usan los agentes de Paperclip (cada
    /// agente dice con qué CLI corre), y si no, el primero que esté. Quien usa Paperclip tiene alguno.
    func detect(force: Bool = false) async -> Detection {
        if !force, let cached = Self.detection, Date().timeIntervalSince(cached.at) < Self.detectionLifetime {
            return cached.value
        }
        var installed: [Engine] = []
        for engine in Engine.clis {
            if await isInstalled(engine) { installed.append(engine) }
        }
        var uses: [String: Int] = [:]
        let companies: [PaperclipCompany] = (try? await api.get("api/companies")) ?? []
        for company in companies where company.status == "active" {
            let agents: [Lossy<Agent>] = (try? await api.get("api/companies/\(company.id)/agents")) ?? []
            for type in agents.compactMap(\.value?.adapterType) { uses[type, default: 0] += 1 }
        }
        // Entre empatados (p. ej. sin agentes), `max` se queda con el primero de la lista.
        let automatic = installed.max { (uses[$0.adapterType ?? ""] ?? 0) < (uses[$1.adapterType ?? ""] ?? 0) }
        let detection = Detection(installed: installed, automatic: automatic)
        Self.detection = (detection, Date())
        return detection
    }

    /// Los modelos que ofrece cada CLI, con su forma oficial de listarlos. Claude Code usa sus alias, que
    /// siempre apuntan al último modelo de cada línea.
    func models(for engine: Engine) async -> [Model] {
        if let cached = Self.models[engine] { return cached }
        var models: [Model] = []
        switch engine {
        case .claude:
            models = [
                Model(id: "opus", title: "Opus"),
                Model(id: "sonnet", title: "Sonnet"),
                Model(id: "haiku", title: "Haiku"),
            ]
        case .codex:
            let result = await runListing("codex debug models")
            if let start = result.firstIndex(of: "{"),
               let catalog = try? JSONDecoder().decode(CodexCatalog.self, from: Data(result[start...].utf8)) {
                models = catalog.models
                    .filter { $0.visibility == nil || $0.visibility == "list" }
                    .map { Model(id: $0.slug, title: $0.displayName ?? $0.slug) }
            }
        case .opencode:
            models = (await runListing("opencode models < /dev/null"))
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { $0.contains("/") && !$0.contains(" ") }
                .map { Model(id: $0, title: $0) }
        case .automatic, .custom:
            return []
        }
        if !models.isEmpty { Self.models[engine] = models }
        return models
    }

    private func isInstalled(_ engine: Engine) async -> Bool {
        let path = await userPath()
        return await Shell.run(["-c", "export PATH=\"$1\"; command -v \(engine.rawValue)", "check", path]).status == 0
    }

    private func runListing(_ command: String) async -> String {
        let path = await userPath()
        return await Shell.run(["-c", "export PATH=\"$1\"; \(command)", "list", path], timeout: 30).output
    }

    private func userPath() async -> String {
        if let path = Self.userPath { return path }
        // Interactivo, para que lea `.zshrc`. Lo que imprima de más queda fuera: solo cuenta la línea marcada.
        let result = await Shell.run(["-i", "-c", "print -r -- \"PAPERCLIP_PATH=$PATH\""], timeout: 30)
        let marker = "PAPERCLIP_PATH="
        let line = result.output.split(separator: "\n").last { $0.hasPrefix(marker) }
        let path = line.map { String($0.dropFirst(marker.count)) } ?? ProcessInfo.processInfo.environment["PATH"] ?? ""
        Self.userPath = path
        return path
    }

    /// Corre el comando en una carpeta vacía (para que no lea las instrucciones de ningún proyecto), con el
    /// PATH de la terminal. `$1` es la carpeta, `$2` el archivo con el texto, `$3` donde deja la respuesta y
    /// `$5` el modelo. Van como argumentos y no dentro del comando, para que ningún texto se ejecute.
    private func run(_ prompt: String, command: String, model: String?) async throws -> String {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "paperclip-explain-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let input = folder.appending(path: "prompt.txt")
        let output = folder.appending(path: "answer.txt")
        try prompt.write(to: input, atomically: true, encoding: .utf8)

        let result = await Shell.run(
            [
                "-c", "export PATH=\"$4\"; cd \"$1\" && " + command,
                "explain", folder.path, input.path, output.path, await userPath(), model ?? "",
            ],
            timeout: Self.timeout
        )
        let answer = ((try? String(contentsOf: output, encoding: .utf8)) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.status == 0, !answer.isEmpty else {
            throw ExplainError.failed(result.tail(2).isEmpty ? "terminó sin respuesta." : result.tail(2))
        }
        return answer
    }

    // MARK: - Lo que se lee

    private struct TaskContext: Decodable {
        let issue: TaskIssue
        let project: TaskProject?
        let continuationSummary: TaskSummary?
    }

    private struct TaskIssue: Decodable {
        let identifier: String?
        let title: String?
        let description: String?
        let status: String?
    }

    private struct TaskProject: Decodable {
        let name: String?
    }

    private struct TaskSummary: Decodable {
        let body: String?
    }

    private struct Agent: Decodable {
        let adapterType: String?
    }

    private struct Comment: Decodable {
        let authorType: String?
        let body: String?
    }

    private struct CodexCatalog: Decodable {
        let models: [CodexModel]
    }

    private struct CodexModel: Decodable {
        let slug: String
        let displayName: String?
        let visibility: String?

        private enum CodingKeys: String, CodingKey {
            case slug, visibility
            case displayName = "display_name"
        }
    }
}
