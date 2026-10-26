import Foundation

/// A YATD database in Notion, reached through any `NotionTransport` (the `ntn` CLI or HTTPS).
public struct NotionSource: TaskSource {
    public let dataSourceID: String
    public let transport: any NotionTransport
    public let calendar: Calendar

    public init(dataSourceID: String, transport: any NotionTransport, calendar: Calendar = .current) {
        self.dataSourceID = dataSourceID
        self.transport = transport
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
        _ = try await transport.api("/v1/pages/\(id)", method: "PATCH", body: ["in_trash": true])
    }

    private func query(filter: [String: Any]) async throws -> [TodoTask] {
        var all: [TodoTask] = []
        var cursor: String?
        repeat {
            var body: [String: Any] = ["filter": filter, "page_size": 100]
            if let cursor { body["start_cursor"] = cursor }
            let data = try await transport.api("/v1/data_sources/\(dataSourceID)/query", method: "POST", body: body)
            let page = try NotionCoding.tasks(fromQueryResponse: data, calendar: calendar)
            all += page.tasks.map { var t = $0; t.projectID = dataSourceID; return t }
            cursor = page.nextCursor
        } while cursor != nil
        return all
    }

    public func create(_ task: TodoTask) async throws -> TodoTask {
        let body: [String: Any] = [
            "parent": ["type": "data_source_id", "data_source_id": dataSourceID],
            "properties": NotionCoding.properties(for: task, calendar: calendar),
        ]
        let data = try await transport.api("/v1/pages", method: "POST", body: body)
        guard let page = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let created = NotionCoding.task(fromPage: page, calendar: calendar)
        else { throw NotionError.unexpectedResponse(String(decoding: data, as: UTF8.self)) }
        var tagged = created
        tagged.projectID = dataSourceID
        return tagged
    }

    public func update(_ id: String, _ changes: [TaskChange]) async throws {
        guard !changes.isEmpty else { return }
        _ = try await transport.api("/v1/pages/\(id)", method: "PATCH",
                              body: ["properties": NotionCoding.properties(for: changes, calendar: calendar)])
    }

    public func metadata() async throws -> SourceMetadata {
        let data = try await transport.api("/v1/data_sources/\(dataSourceID)", method: "GET")
        guard let ds = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw NotionError.unexpectedResponse(String(decoding: data, as: UTF8.self)) }
        let title = (ds["title"] as? [[String: Any]] ?? []).compactMap { $0["plain_text"] as? String }.joined()
        let parent = (ds["database_parent"] as? [String: Any])?["page_id"] as? String
        return SourceMetadata(title: title, parentPageID: parent)
    }

    public func ensureSchema() async throws {
        let data = try await transport.api("/v1/data_sources/\(dataSourceID)", method: "GET")
        guard let ds = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let existing = ds["properties"] as? [String: Any]
        else { throw NotionError.unexpectedResponse(String(decoding: data, as: UTF8.self)) }
        let missing = Schema.addedProperties.filter { existing[$0.key] == nil }
        guard !missing.isEmpty else { return }
        _ = try await transport.api("/v1/data_sources/\(dataSourceID)", method: "PATCH", body: ["properties": missing])
    }

    // MARK: Setup

    /// Creates a "YATD" page with an inline Tasks database, at the top of the workspace or inside
    /// `parentPageID`. Internal integrations (token connections) can't create workspace-level pages,
    /// so they need a parent page shared with them.
    public static func bootstrap(transport: any NotionTransport, parentPageID: String? = nil) async throws -> SourceConfig {
        try await createPageWithDatabase(transport: transport, parentPageID: parentPageID,
                                         pageTitle: "YATD", emoji: "✅", databaseTitle: "Tasks")
    }

    /// A page's title and the page it sits in (nil at the workspace top level).
    public static func pageInfo(_ pageID: String, transport: any NotionTransport) async throws -> SourceMetadata {
        let data = try await transport.api("/v1/pages/\(pageID)", method: "GET")
        guard let page = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw NotionError.unexpectedResponse(String(decoding: data, as: UTF8.self)) }
        let props = page["properties"] as? [String: Any] ?? [:]
        let titleProp = props.values.compactMap { $0 as? [String: Any] }.first { $0["type"] as? String == "title" }
        let title = (titleProp?["title"] as? [[String: Any]] ?? []).compactMap { $0["plain_text"] as? String }.joined()
        let parent = (page["parent"] as? [String: Any])?["page_id"] as? String
        return SourceMetadata(title: title, parentPageID: parent)
    }

    /// Creates a project: a page named `name` inside `parentPageID` (the YATD page) with its own
    /// tasks database. The database is titled after the project so discovery can name it.
    public static func createProject(named name: String, parentPageID: String,
                                     transport: any NotionTransport) async throws -> Project {
        let config = try await createPageWithDatabase(transport: transport, parentPageID: parentPageID,
                                                      pageTitle: name, emoji: "📁", databaseTitle: name)
        return Project(config, name: name)
    }

    private static func createPageWithDatabase(transport: any NotionTransport, parentPageID: String?,
                                               pageTitle: String, emoji: String, databaseTitle: String) async throws -> SourceConfig {
        let parent: [String: Any] = parentPageID.map { ["type": "page_id", "page_id": $0] }
            ?? ["type": "workspace", "workspace": true]
        let pageData = try await transport.api("/v1/pages", method: "POST", body: [
            "parent": parent,
            "icon": ["type": "emoji", "emoji": emoji],
            "properties": ["title": ["title": [["text": ["content": pageTitle]]]]],
        ])
        guard let page = try JSONSerialization.jsonObject(with: pageData) as? [String: Any],
              let pageID = page["id"] as? String
        else { throw NotionError.unexpectedResponse(String(decoding: pageData, as: UTF8.self)) }

        let dbData = try await transport.api("/v1/databases", method: "POST",
                                             body: Schema.createDatabaseBody(parentPageID: pageID, title: databaseTitle))
        guard let db = try JSONSerialization.jsonObject(with: dbData) as? [String: Any],
              let sources = db["data_sources"] as? [[String: Any]],
              let dsID = sources.first?["id"] as? String
        else { throw NotionError.unexpectedResponse(String(decoding: dbData, as: UTF8.self)) }

        return SourceConfig(dataSourceID: dsID, pageURL: (page["url"] as? String).flatMap(URL.init(string:)))
    }

    /// Finds databases in the workspace with the YATD schema, most recently edited first.
    public static func discover(transport: any NotionTransport) async throws -> [DiscoveredDatabase] {
        var found: [DiscoveredDatabase] = []
        var cursor: String?
        repeat {
            var body: [String: Any] = ["filter": ["property": "object", "value": "data_source"], "page_size": 100]
            if let cursor { body["start_cursor"] = cursor }
            let data = try await transport.api("/v1/search", method: "POST", body: body)
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
    /// A page URL instead creates a new YATD database inside that page.
    public static func resolve(_ input: String, transport: any NotionTransport) async throws -> SourceConfig {
        guard let id = NotionCoding.extractID(input) else { throw NotionError.notConfigured }
        if let data = try? await transport.api("/v1/data_sources/\(id)", method: "GET"),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           obj["object"] as? String == "data_source" {
            return SourceConfig(dataSourceID: id, pageURL: URL(string: input))
        }
        if let data = try? await transport.api("/v1/pages/\(id)", method: "GET"),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           obj["object"] as? String == "page" {
            return try await bootstrap(transport: transport, parentPageID: id)
        }
        let data = try await transport.api("/v1/databases/\(id)", method: "GET")
        guard let db = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dsID = (db["data_sources"] as? [[String: Any]])?.first?["id"] as? String
        else { throw NotionError.unexpectedResponse(String(decoding: data, as: UTF8.self)) }
        return SourceConfig(dataSourceID: dsID, pageURL: URL(string: input))
    }
}

