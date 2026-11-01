import Foundation
import OSLog

// El tope diario de corridas de un agente (`runtimeConfig.heartbeat.maxDailyRuns`). Al llegar, Paperclip
// 2026.1023.0 salta en silencio todo lo que lo despertaría (`heartbeat.daily_run_limit`) y Decisions no lo
// muestra: la app avisa en la Mac y en Telegram. Lo que se lee, a la defensiva, como Decisions.

/// Un agente de `GET /api/companies/{id}/agents`. Solo `id` es obligatorio.
struct RunLimitAgent: Decodable, Sendable {
    let id: String
    let name: String?
    /// Lo que va en la dirección de su página.
    let urlKey: String?
    let status: String?
    /// `nil`: sin tope.
    let maxDailyRuns: Int?
    /// El tope no es un número (p. ej. el texto "60"): Paperclip lo toma como 0 y la app no avisa.
    let limitUnreadable: Bool

    private enum CodingKeys: String, CodingKey { case id, name, urlKey, status, runtimeConfig }
    private enum RuntimeKeys: String, CodingKey { case heartbeat }
    /// Como `parseHeartbeatPolicy` de Paperclip: el primero de estos que tenga valor.
    private enum HeartbeatKeys: String, CodingKey, CaseIterable {
        case maxDailyRuns, dailyRunLimit, dailyRunCap, maxRunsPerDay
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try? container.decodeIfPresent(String.self, forKey: .name)
        urlKey = try? container.decodeIfPresent(String.self, forKey: .urlKey)
        status = try? container.decodeIfPresent(String.self, forKey: .status)
        let heartbeat = try? container.nestedContainer(keyedBy: RuntimeKeys.self, forKey: .runtimeConfig)
            .nestedContainer(keyedBy: HeartbeatKeys.self, forKey: .heartbeat)
        let value = HeartbeatKeys.allCases.lazy
            .compactMap { key in heartbeat.flatMap { try? $0.decodeIfPresent(LimitValue.self, forKey: key) } }
            .first
        maxDailyRuns = value?.limit
        limitUnreadable = value?.unreadable ?? false
    }

    /// Lo que Paperclip hace con el valor (`normalizeOptionalNonNegativeInteger`): un número se redondea hacia
    /// abajo y, si es negativo, no hay tope; un texto vacío tampoco; cualquier otra cosa (un texto con un
    /// número, `true`) cuenta como 0. `null` no tiene valor y sigue con el próximo nombre.
    private struct LimitValue: Decodable {
        let limit: Int?
        var unreadable = false

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() {
                throw DecodingError.valueNotFound(Int.self, .init(codingPath: decoder.codingPath, debugDescription: "null"))
            }
            if let number = try? container.decode(Double.self) {
                guard number.isFinite else { limit = 0; unreadable = true; return }
                let floored = number.rounded(.down)
                limit = floored >= 0 ? Int(min(floored, Double(Int.max / 2))) : nil
            } else if let text = try? container.decode(String.self), text.isEmpty {
                limit = nil
            } else {
                limit = 0
                unreadable = true
            }
        }
    }
}

/// Una corrida de `GET /api/companies/{id}/heartbeat-runs?summary=true`.
struct RunLimitRun: Decodable, Sendable {
    let status: String?
    let startedAt: String?
}

enum RunLimit {
    /// Las corridas que Paperclip no cuenta: las que todavía no empezaron.
    private static let uncounted: Set<String> = ["queued", "scheduled_retry"]

    /// El día de Paperclip para el tope: el día UTC en curso, de medianoche a medianoche.
    static func utcDay(containing date: Date) -> (start: Date, end: Date, key: String) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(24 * 60 * 60)
        let parts = calendar.dateComponents([.year, .month, .day], from: start)
        let key = String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        return (start, end, key)
    }

    /// Como `getHeartbeatDailyCapBlock`: las que empezaron hoy (UTC), sin las que siguen en cola.
    static func countToday(_ runs: [RunLimitRun], now: Date) -> Int {
        let day = utcDay(containing: now)
        return runs.count { run in
            guard !uncounted.contains(run.status ?? ""), let started = PaperclipDate.parse(run.startedAt) else { return false }
            return started >= day.start && started < day.end
        }
    }
}

/// Lo que se le cuenta al usuario de un agente que llegó a su tope.
struct RunLimitNotice: Sendable {
    let agentName: String
    let limit: Int
    /// La próxima medianoche UTC, cuando Paperclip vuelve a contar desde cero.
    let resetsAt: Date
    let href: String?
}

/// Los textos del aviso, en la Mac y en Telegram.
enum RunLimitFormat {
    static func title(_ notice: RunLimitNotice) -> String {
        String(localized: "⛔ \(notice.agentName) hit its daily run limit")
    }

    /// Su tope, que lo que se le pida no va a correr y a qué hora local se reinicia la cuenta.
    static func body(_ notice: RunLimitNotice, now: Date = Date()) -> String {
        let perDay = String(localized: "\(notice.limit) runs a day")
        let resets = resetTime(notice.resetsAt, now: now)
        return String(localized: "Its limit is \(perDay). The count resets \(resets), and until then anything you ask of it won’t run.")
    }

    /// «hoy a las 19:00» o «mañana a las 9:00»: en la zona horaria y el formato de la Mac.
    static func resetTime(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.autoupdatingCurrent
        let time = date.formatted(.dateTime.hour().minute())
        if calendar.isDate(date, inSameDayAs: now) { return String(localized: "today at \(time)") }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            return String(localized: "tomorrow at \(time)")
        }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    static func telegram(_ notice: RunLimitNotice, now: Date = Date()) -> String {
        "<b>\(TelegramFormat.escape(title(notice)))</b>\n\(TelegramFormat.escape(body(notice, now: now)))\n"
            + String(localized: "<i>You can raise the limit on its page in Paperclip.</i>")
    }
}

/// Avisa cuando un agente llega a su tope diario de corridas: un aviso en la Mac y un mensaje en Telegram, uno
/// por agente, por día UTC y por valor del tope (si lo suben y llega al nuevo el mismo día, avisa otra vez). Lo
/// avisado se guarda en la Mac, así que reabrir la app no lo repite. No suma al número del Dock.
///
/// Corre dentro de la revisión de Decisions (`DecisionsMonitor`), pero cada `checkInterval` por company: una
/// lectura de agentes y, de los que tienen tope y todavía no se avisaron hoy con ese tope, una de corridas por
/// agente, todas a la vez. Los demás (sin tope, con tope 0, en pausa o dados de baja) no se miran.
@MainActor
final class RunLimitMonitor {
    /// Cada cuánto se revisa una company. Un aviso llega, como mucho, unos minutos después del tope: lo que
    /// importa es que no pase la tarde sin saberse.
    private static let checkInterval: TimeInterval = 3 * 60
    /// Las corridas se piden de la más nueva a la más vieja: unas más que el tope cubren el día, también las
    /// que Paperclip canceló en cola al llegar. Si no alcanzan, la próxima vez se piden el doble.
    private static let runsMargin = 10
    private static let runsMax = 1000
    /// Los que no corren aunque no lleguen al tope.
    private static let idle: Set<String> = ["paused", "terminated"]
    /// Lo ya avisado: «agente|día UTC|tope».
    private static let noticesKey = "runLimitNotices"
    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "PaperclipDispatch", category: "run-limits")

    /// Para mandar el aviso; sin bot vinculado, solo avisa en la Mac.
    weak var telegram: TelegramChannel?

    private let api: PaperclipAPI
    private let preferences: Preferences
    private let notifications: NotificationBridge
    private let defaults: UserDefaults
    private let now: () -> Date
    private var checkedAt: [String: Date] = [:]
    /// Cuántas corridas pedir de un agente, si la última vez no alcanzaron.
    private var window: [String: Int] = [:]

    init(
        api: PaperclipAPI,
        preferences: Preferences,
        notifications: NotificationBridge,
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init
    ) {
        self.api = api
        self.preferences = preferences
        self.notifications = notifications
        self.defaults = defaults
        self.now = now
    }

    /// Una company en una revisión de Decisions que salió bien. Si algo falla, se vuelve a intentar en la
    /// próxima revisión de esa company.
    func review(_ company: PaperclipCompany) async {
        guard preferences.runLimitNotifications else { return }
        let started = now()
        if let last = checkedAt[company.id], started.timeIntervalSince(last) < Self.checkInterval { return }
        checkedAt[company.id] = started
        guard let agents: [Lossy<RunLimitAgent>] = try? await api.get("api/companies/\(company.id)/agents") else {
            checkedAt[company.id] = nil
            return
        }
        let day = RunLimit.utcDay(containing: started)
        var notified = Set(defaults.stringArray(forKey: Self.noticesKey) ?? [])
        // Lo de otros días ya no sirve.
        let today = notified.filter { $0.split(separator: "|").dropFirst().first.map(String.init) == day.key }
        if today != notified {
            notified = today
            defaults.set(Array(notified), forKey: Self.noticesKey)
        }
        // Un agente en pausa o dado de baja no corre igual, y uno con tope 0 está apagado a propósito: avisarlo
        // cada día sería ruido.
        for agent in agents.compactMap(\.value) where agent.limitUnreadable {
            Unexpected.note("api/companies/\(company.id)/agents", "\(agent.id): maxDailyRuns isn’t a number, no notice")
        }
        let watched = agents.compactMap(\.value).filter { agent in
            guard let limit = agent.maxDailyRuns, limit > 0, !Self.idle.contains(agent.status ?? "") else { return false }
            return !notified.contains(Self.key(agent, day: day.key, limit: limit))
        }
        guard !watched.isEmpty else { return }

        // Las de todos a la vez: una lectura por agente.
        let windows = window
        let counts = await withTaskGroup(of: (RunLimitAgent, Int, Int?, Bool).self) { group in
            for agent in watched {
                let limit = agent.maxDailyRuns ?? 0
                let size = windows[agent.id] ?? min(limit + Self.runsMargin, Self.runsMax)
                group.addTask {
                    let count = await self.countRuns(agent, company: company, size: size, now: started)
                    return (agent, size, count?.today, count?.full ?? false)
                }
            }
            var results: [(agent: RunLimitAgent, size: Int, today: Int?, full: Bool)] = []
            for await result in group { results.append(result) }
            return results
        }

        for (agent, size, today, full) in counts {
            guard let limit = agent.maxDailyRuns, let today else { continue }
            Self.log.notice("\(agent.name ?? agent.id, privacy: .public): \(today, privacy: .public) of \(limit, privacy: .public) runs today")
            if today < limit {
                // La página vino llena sin llegar al tope (muchas en cola o canceladas): la próxima vez, más.
                window[agent.id] = full && size < Self.runsMax ? min(size * 2, Self.runsMax) : nil
                continue
            }
            window[agent.id] = nil
            // Mientras se leía pudieron apagarlo en Ajustes.
            guard preferences.runLimitNotifications else { return }
            await announce(agent, limit: limit, resetsAt: day.end, company: company)
            notified.insert(Self.key(agent, day: day.key, limit: limit))
            defaults.set(Array(notified), forKey: Self.noticesKey)
        }
    }

    /// Las corridas de hoy de un agente, y si la página vino llena; `nil` si no se pudo leer.
    private func countRuns(_ agent: RunLimitAgent, company: PaperclipCompany, size: Int, now: Date)
        async -> (today: Int, full: Bool)? {
        do {
            let runs: [Lossy<RunLimitRun>] = try await api.get(
                "api/companies/\(company.id)/heartbeat-runs",
                query: [
                    URLQueryItem(name: "agentId", value: agent.id),
                    URLQueryItem(name: "limit", value: String(size)),
                    URLQueryItem(name: "summary", value: "true"),
                ]
            )
            return (RunLimit.countToday(runs.compactMap(\.value), now: now), runs.count >= size)
        } catch {
            return nil
        }
    }

    private static func key(_ agent: RunLimitAgent, day: String, limit: Int) -> String {
        "\(agent.id)|\(day)|\(limit)"
    }

    private func announce(_ agent: RunLimitAgent, limit: Int, resetsAt: Date, company: PaperclipCompany) async {
        let notice = RunLimitNotice(
            agentName: agent.name ?? String(localized: "An agent"),
            limit: limit,
            resetsAt: resetsAt,
            href: Self.agentHref(agent, prefix: company.issuePrefix)
        )
        Self.log.notice("\(agent.name ?? agent.id, privacy: .public): daily limit of \(limit, privacy: .public) reached, notice")
        let id = "run-limit-\(agent.id)-\(limit)"
        // También con la ventana al frente: Paperclip no lo muestra en ningún lado.
        notifications.show(
            id: id, tag: id, title: RunLimitFormat.title(notice), body: RunLimitFormat.body(notice), href: notice.href,
            openLabel: String(localized: "Open agent")
        )
        if let telegram, telegram.noticeChatId != nil {
            _ = await telegram.postNotice(
                RunLimitFormat.telegram(notice), href: notice.href, linkLabel: String(localized: "Open agent")
            )
        }
    }

    /// Como arma Paperclip 2026.1023.0 el enlace de un agente: `/<prefijo>/agents/<urlKey o id>`.
    static func agentHref(_ agent: RunLimitAgent, prefix: String?) -> String {
        let key = agent.urlKey.flatMap { $0.isEmpty ? nil : $0 } ?? agent.id
        let path = "agents/\(key.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? key)"
        return prefix.map { "/\($0)/\(path)" } ?? "/\(path)"
    }
}
