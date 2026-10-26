import Foundation

/// Talks to Notion by running the `ntn` CLI, reusing its login.
public struct NtnCLISource: TaskSource {
    public let dataSourceID: String
    public let cli: NtnCLI
    public let calendar: Calendar

    public init(dataSourceID: String, cli: NtnCLI, calendar: Calendar = .current) {
        self.dataSourceID = dataSourceID
        self.cli = cli
        self.calendar = calendar
    }

    public func fetchOpen() async throws -> [TodoTask] {
        try await query(filter: ["property": Schema.done, "checkbox": ["equals": false]])
    }

    public func fetchDone(on day: Date) async throws -> [TodoTask] {
        // Notion's date filters compare in UTC, so query a 3-day window and trim locally.
        let from = calendar.date(byAdding: .day, value: -1, to: day)!
        let to = calendar.date(byAdding: .day, value: 2, to: day)!
        let tasks = try await query(filter: ["and": [
            ["property": Schema.done, "checkbox": ["equals": true]],
            ["property": Schema.date, "date": ["on_or_after": NotionCoding.dateString(from, hasTime: false, calendar: calendar)]],
            ["property": Schema.date, "date": ["before": NotionCoding.dateString(to, hasTime: false, calendar: calendar)]],
        ]])
        return tasks.filter { $0.date.map { calendar.isDate($0.start, inSameDayAs: day) } ?? false }
    }

    public func openTasks(titled title: String) async throws -> [TodoTask] {
        try await query(filter: ["and": [
            ["property": Schema.name, "title": ["equals": title]],
            ["property": Schema.done, "checkbox": ["equals": false]],
        ]])
    }

    public func trash(_ id: String) async throws {
        _ = try await cli.api("/v1/pages/\(id)", method: "PATCH", body: ["in_trash": true])
    }

    private func query(filter: [String: Any]) async throws -> [TodoTask] {
        var all: [TodoTask] = []
        var cursor: String?
        repeat {
            var body: [String: Any] = ["filter": filter, "page_size": 100]
            if let cursor { body["start_cursor"] = cursor }
            let data = try await cli.api("/v1/data_sources/\(dataSourceID)/query", method: "POST", body: body)
            let page = try NotionCoding.tasks(fromQueryResponse: data, calendar: calendar)
            all += page.tasks
            cursor = page.nextCursor
        } while cursor != nil
        return all
    }

    public func create(_ task: TodoTask) async throws -> TodoTask {
        let body: [String: Any] = [
            "parent": ["type": "data_source_id", "data_source_id": dataSourceID],
            "properties": NotionCoding.properties(for: task, calendar: calendar),
        ]
        let data = try await cli.api("/v1/pages", method: "POST", body: body)
        guard let page = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let created = NotionCoding.task(fromPage: page, calendar: calendar)
        else { throw NotionError.unexpectedResponse(String(decoding: data, as: UTF8.self)) }
        return created
    }

    public func update(_ id: String, _ changes: [TaskChange]) async throws {
        guard !changes.isEmpty else { return }
        _ = try await cli.api("/v1/pages/\(id)", method: "PATCH",
                              body: ["properties": NotionCoding.properties(for: changes, calendar: calendar)])
    }

    public func ensureSchema() async throws {
        let data = try await cli.api("/v1/data_sources/\(dataSourceID)", method: "GET")
        guard let ds = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let existing = ds["properties"] as? [String: Any]
        else { throw NotionError.unexpectedResponse(String(decoding: data, as: UTF8.self)) }
        let missing = Schema.addedProperties.filter { existing[$0.key] == nil }
        guard !missing.isEmpty else { return }
        _ = try await cli.api("/v1/data_sources/\(dataSourceID)", method: "PATCH", body: ["properties": missing])
    }

    // MARK: Setup

    /// Creates a "YATD" page at the top of the workspace with an inline Tasks database.
    public static func bootstrap(cli: NtnCLI) async throws -> SourceConfig {
        let pageData = try await cli.api("/v1/pages", method: "POST", body: [
            "parent": ["type": "workspace", "workspace": true],
            "icon": ["type": "emoji", "emoji": "✅"],
            "properties": ["title": ["title": [["text": ["content": "YATD"]]]]],
        ])
        guard let page = try JSONSerialization.jsonObject(with: pageData) as? [String: Any],
              let pageID = page["id"] as? String
        else { throw NotionError.unexpectedResponse(String(decoding: pageData, as: UTF8.self)) }

        let dbData = try await cli.api("/v1/databases", method: "POST", body: Schema.createDatabaseBody(parentPageID: pageID))
        guard let db = try JSONSerialization.jsonObject(with: dbData) as? [String: Any],
              let sources = db["data_sources"] as? [[String: Any]],
              let dsID = sources.first?["id"] as? String
        else { throw NotionError.unexpectedResponse(String(decoding: dbData, as: UTF8.self)) }

        return SourceConfig(dataSourceID: dsID, pageURL: (page["url"] as? String).flatMap(URL.init(string:)))
    }

    /// Finds databases in the workspace with the YATD schema, most recently edited first.
    public static func discover(cli: NtnCLI) async throws -> [DiscoveredDatabase] {
        var found: [DiscoveredDatabase] = []
        var cursor: String?
        repeat {
            var body: [String: Any] = ["filter": ["property": "object", "value": "data_source"], "page_size": 100]
            if let cursor { body["start_cursor"] = cursor }
            let data = try await cli.api("/v1/search", method: "POST", body: body)
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = root["results"] as? [[String: Any]]
            else { throw NotionError.unexpectedResponse(String(decoding: data, as: UTF8.self)) }
            for ds in results {
                guard let id = ds["id"] as? String,
                      ds["in_trash"] as? Bool != true,
                      let props = ds["properties"] as? [String: Any],
                      Schema.matches(properties: props)
                else { continue }
                let title = (ds["title"] as? [[String: Any]] ?? []).compactMap { $0["plain_text"] as? String }.joined()
                let edited = (ds["last_edited_time"] as? String).flatMap { NotionCoding.parseDate($0, calendar: .current)?.date }
                found.append(DiscoveredDatabase(
                    config: SourceConfig(dataSourceID: id, pageURL: (ds["url"] as? String).flatMap(URL.init(string:))),
                    title: title.isEmpty ? "Untitled" : title,
                    lastEdited: edited
                ))
            }
            cursor = (root["has_more"] as? Bool == true) ? root["next_cursor"] as? String : nil
        } while cursor != nil
        return found.sorted { ($0.lastEdited ?? .distantPast) > ($1.lastEdited ?? .distantPast) }
    }

    /// Accepts a data source ID, database ID or URL to either, and returns the data source ID.
    public static func resolve(_ input: String, cli: NtnCLI) async throws -> SourceConfig {
        guard let id = NotionCoding.extractID(input) else { throw NotionError.notConfigured }
        if let data = try? await cli.api("/v1/data_sources/\(id)", method: "GET"),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           obj["object"] as? String == "data_source" {
            return SourceConfig(dataSourceID: id, pageURL: URL(string: input))
        }
        let data = try await cli.api("/v1/databases/\(id)", method: "GET")
        guard let db = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dsID = (db["data_sources"] as? [[String: Any]])?.first?["id"] as? String
        else { throw NotionError.unexpectedResponse(String(decoding: data, as: UTF8.self)) }
        return SourceConfig(dataSourceID: dsID, pageURL: URL(string: input))
    }
}

/// Runs `ntn`. stdin must be closed: with it open, `ntn api` waits for input and hangs.
public struct NtnCLI: Sendable {
    public let executable: URL

    public init(executable: URL) {
        self.executable = executable
    }

    /// Finds `ntn` at an explicit path, in common install locations, or via the login shell's PATH.
    public static func locate(preferred: String? = nil) -> NtnCLI? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        var candidates = [preferred].compactMap { $0 }.filter { !$0.isEmpty }
        candidates += ["\(home)/.local/bin/ntn", "/opt/homebrew/bin/ntn", "/usr/local/bin/ntn"]
        if let path = candidates.first(where: { fm.isExecutableFile(atPath: $0) }) {
            return NtnCLI(executable: URL(fileURLWithPath: path))
        }
        // GUI apps don't inherit the shell PATH; ask a login shell.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", "command -v ntn"]
        let out = Pipe()
        p.standardOutput = out
        p.standardInput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        let path = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return fm.isExecutableFile(atPath: path) ? NtnCLI(executable: URL(fileURLWithPath: path)) : nil
    }

    public func api(_ path: String, method: String, body: [String: Any]? = nil) async throws -> Data {
        var args = ["api", path, "-X", method]
        if let body {
            let json = try JSONSerialization.data(withJSONObject: body)
            args += ["-d", String(decoding: json, as: UTF8.self)]
        }
        return try await run(args)
    }

    public func run(_ args: [String], timeout: TimeInterval = 30) async throws -> Data {
        let executable = executable
        return try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = executable
                p.arguments = args
                p.standardInput = FileHandle.nullDevice
                let out = Pipe(), err = Pipe()
                p.standardOutput = out
                p.standardError = err
                do { try p.run() } catch {
                    cont.resume(throwing: NotionError.cliNotFound)
                    return
                }
                let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
                // Read both pipes before waiting so large outputs can't deadlock.
                let errBox = DataBox()
                let errDone = DispatchSemaphore(value: 0)
                DispatchQueue.global().async {
                    errBox.data = err.fileHandleForReading.readDataToEndOfFile()
                    errDone.signal()
                }
                let data = out.fileHandleForReading.readDataToEndOfFile()
                errDone.wait()
                let errData = errBox.data
                p.waitUntilExit()
                killer.cancel()
                if p.terminationStatus == 0 {
                    cont.resume(returning: data)
                } else {
                    let msg = String(decoding: errData.isEmpty ? data : errData, as: UTF8.self)
                    cont.resume(throwing: NotionError.cliFailed(status: p.terminationStatus, stderr: msg))
                }
            }
        }
    }
}

/// Written once by the stderr reader, read after its semaphore signals.
private final class DataBox: @unchecked Sendable {
    var data = Data()
}
