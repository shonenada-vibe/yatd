import Foundation

/// Converts between Notion page JSON and `TodoTask`.
public enum NotionCoding {
    // MARK: Decoding

    public static func tasks(fromQueryResponse data: Data, calendar: Calendar = .current) throws -> (tasks: [TodoTask], nextCursor: String?) {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = root["results"] as? [[String: Any]]
        else { throw NotionError.unexpectedResponse(String(decoding: data, as: UTF8.self)) }
        let cursor = (root["has_more"] as? Bool == true) ? root["next_cursor"] as? String : nil
        return (results.compactMap { task(fromPage: $0, calendar: calendar) }, cursor)
    }

    public static func task(fromPage page: [String: Any], calendar: Calendar = .current) -> TodoTask? {
        guard let id = page["id"] as? String,
              let props = page["properties"] as? [String: Any]
        else { return nil }
        if page["in_trash"] as? Bool == true { return nil }

        let title = ((props[Schema.name] as? [String: Any])?["title"] as? [[String: Any]] ?? [])
            .compactMap { $0["plain_text"] as? String }
            .joined()
        let done = (props[Schema.done] as? [String: Any])?["checkbox"] as? Bool ?? false
        let priority = selectName(props[Schema.priority]).flatMap(Priority.init(rawValue:))
        let rep = selectName(props[Schema.repeat]).flatMap(Repeat.init(rawValue:))
        let order = (props[Schema.order] as? [String: Any])?["number"] as? Double

        var date: TaskDate?
        if let d = (props[Schema.date] as? [String: Any])?["date"] as? [String: Any],
           let s = d["start"] as? String,
           let start = parseDate(s, calendar: calendar) {
            let end = (d["end"] as? String).flatMap { parseDate($0, calendar: calendar) }
            date = TaskDate(start: start.date, end: end?.date, hasTime: start.hasTime)
        }

        let startedAt = dateTime(props[Schema.started], calendar: calendar)
        let finishedAt = dateTime(props[Schema.finished], calendar: calendar)
        let plannedStart = dateTime(props[Schema.plannedStart], calendar: calendar)

        let created = (page["created_time"] as? String).flatMap { parseDate($0, calendar: calendar)?.date } ?? .distantPast
        let url = (page["url"] as? String).flatMap(URL.init(string:))
        var task = TodoTask(id: id, title: title, done: done, date: date, priority: priority,
                            repeat: rep, order: order, startedAt: startedAt, finishedAt: finishedAt,
                            createdTime: created, url: url)
        task.plannedStart = plannedStart
        return task
    }

    private static func dateTime(_ prop: Any?, calendar: Calendar) -> Date? {
        guard let s = ((prop as? [String: Any])?["date"] as? [String: Any])?["start"] as? String else { return nil }
        return parseDate(s, calendar: calendar)?.date
    }

    private static func selectName(_ prop: Any?) -> String? {
        ((prop as? [String: Any])?["select"] as? [String: Any])?["name"] as? String
    }

    /// Parses `2026-10-26` (local all-day) or an ISO 8601 date-time.
    static func parseDate(_ s: String, calendar: Calendar) -> (date: Date, hasTime: Bool)? {
        if s.count == 10 {
            let parts = s.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 3,
                  let d = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
            else { return nil }
            return (d, false)
        }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return (d, true) }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s).map { ($0, true) }
    }

    // MARK: Encoding

    public static func dateString(_ date: Date, hasTime: Bool, calendar: Calendar = .current) -> String {
        if hasTime {
            let f = ISO8601DateFormatter()
            f.timeZone = calendar.timeZone
            f.formatOptions = [.withInternetDateTime]
            return f.string(from: date)
        }
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    public static func dateProperty(_ date: TaskDate?, calendar: Calendar = .current) -> [String: Any] {
        guard let date else { return ["date": NSNull()] }
        var d: [String: Any] = ["start": dateString(date.start, hasTime: date.hasTime, calendar: calendar)]
        if let end = date.end { d["end"] = dateString(end, hasTime: date.hasTime, calendar: calendar) }
        return ["date": d]
    }

    /// A date-time property holding a single moment, or empty when `nil`.
    public static func timestampProperty(_ date: Date?, calendar: Calendar = .current) -> [String: Any] {
        dateProperty(date.map { TaskDate(start: $0, hasTime: true) }, calendar: calendar)
    }

    /// Properties for creating a page in the YATD data source.
    public static func properties(for task: TodoTask, calendar: Calendar = .current) -> [String: Any] {
        var p: [String: Any] = [
            Schema.name: ["title": [["text": ["content": task.title]]]],
            Schema.done: ["checkbox": task.done],
        ]
        if task.date != nil { p[Schema.date] = dateProperty(task.date, calendar: calendar) }
        if let pr = task.priority { p[Schema.priority] = ["select": ["name": pr.rawValue]] }
        if let r = task.repeat { p[Schema.repeat] = ["select": ["name": r.rawValue]] }
        if let o = task.order { p[Schema.order] = ["number": o] }
        if task.startedAt != nil { p[Schema.started] = timestampProperty(task.startedAt, calendar: calendar) }
        if task.finishedAt != nil { p[Schema.finished] = timestampProperty(task.finishedAt, calendar: calendar) }
        if task.plannedStart != nil { p[Schema.plannedStart] = timestampProperty(task.plannedStart, calendar: calendar) }
        return p
    }

    /// Properties for a `PATCH /v1/pages/{id}` applying `changes`.
    public static func properties(for changes: [TaskChange], calendar: Calendar = .current) -> [String: Any] {
        var p: [String: Any] = [:]
        for change in changes {
            switch change {
            case .done(let done): p[Schema.done] = ["checkbox": done]
            case .date(let date): p[Schema.date] = dateProperty(date, calendar: calendar)
            case .startedAt(let d): p[Schema.started] = timestampProperty(d, calendar: calendar)
            case .finishedAt(let d): p[Schema.finished] = timestampProperty(d, calendar: calendar)
            case .plannedStart(let d): p[Schema.plannedStart] = timestampProperty(d, calendar: calendar)
            }
        }
        return p
    }

    /// Extracts a Notion ID (32 hex chars, dashed or not) from a URL or raw ID and returns it dashed.
    public static func extractID(_ input: String) -> String? {
        let lower = input.lowercased()
        let dashed = "(?<![0-9a-f])[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}(?![0-9a-f])"
        if let r = lower.range(of: dashed, options: .regularExpression) { return String(lower[r]) }
        // Notion URLs end the slug with the bare ID: /p/Title-<32 hex>?v=...
        guard let r = lower.range(of: "(?<![0-9a-f])[0-9a-f]{32}(?![0-9a-f])", options: .regularExpression) else { return nil }
        let s = Array(lower[r])
        return [0..<8, 8..<12, 12..<16, 16..<20, 20..<32].map { String(s[$0]) }.joined(separator: "-")
    }
}

public enum NotionError: LocalizedError {
    case unexpectedResponse(String)
    case cliNotFound
    case cliFailed(status: Int32, stderr: String)
    case notConfigured
    case notSignedIn
    case httpFailed(status: Int, body: String)

    public var errorDescription: String? {
        switch self {
        case .unexpectedResponse(let body): "Unexpected Notion response: \(body.prefix(300))"
        case .cliNotFound: "Couldn't find the `ntn` CLI. Install it or set its path in Settings."
        case .cliFailed(let status, let stderr): "ntn exited with \(status): \(stderr.prefix(300))"
        case .notConfigured: "No Notion database configured yet."
        case .notSignedIn: "Add a Notion integration token in Settings."
        case .httpFailed(401, _): "Notion rejected the token. Check it in Settings."
        case .httpFailed(404, _): "Notion can't find that page. Share it with your integration (••• → Connections)."
        case .httpFailed(let status, let body): "Notion error \(status): \(body.prefix(300))"
        }
    }
}
