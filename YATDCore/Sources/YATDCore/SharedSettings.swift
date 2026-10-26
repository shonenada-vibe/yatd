import Foundation

/// Settings every Mac should agree on, stored as JSON in a code block on the YATD page.
public struct SharedSettings: Codable, Sendable, Equatable {
    public var version: Int
    public var projects: [Project]
    public var rules: [ScheduleRule]
    public var dayStartHour: Int?

    public init(version: Int = 1, projects: [Project], rules: [ScheduleRule], dayStartHour: Int?) {
        self.version = version
        self.projects = projects
        self.rules = rules
        self.dayStartHour = dayStartHour
    }

    /// Combines a Mac's settings from before sharing (`local`) into the shared copy (`self`):
    /// shared entries first and unchanged, then anything only this Mac had.
    public func merged(withLocal local: SharedSettings) -> SharedSettings {
        let projectIDs = Set(projects.map(\.id))
        let ruleIDs = Set(rules.map(\.id))
        return SharedSettings(
            version: version,
            projects: projects + local.projects.filter { !projectIDs.contains($0.id) },
            rules: rules + local.rules.filter { !ruleIDs.contains($0.id) },
            dayStartHour: dayStartHour ?? local.dayStartHour
        )
    }

    public func json() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }

    public static func decode(_ json: String) throws -> SharedSettings {
        try JSONDecoder().decode(SharedSettings.self, from: Data(json.utf8))
    }
}

/// Reads and writes the shared settings: a "YATD settings" toggle on the YATD page holding a
/// JSON code block. Visible (and hand-editable) in Notion, collapsed out of the way.
public struct NotionSettingsDocument: Sendable {
    public static let toggleTitle = "YATD settings"

    public let rootPageID: String
    public let transport: any NotionTransport

    public init(rootPageID: String, transport: any NotionTransport) {
        self.rootPageID = rootPageID
        self.transport = transport
    }

    public struct Loaded: Sendable {
        public var settings: SharedSettings?
        /// The code block holding the JSON, if the toggle exists.
        public var codeBlockID: String?
    }

    public func load() async throws -> Loaded {
        guard let toggle = try await children(of: rootPageID).first(where: isSettingsToggle),
              let toggleID = toggle["id"] as? String
        else { return Loaded(settings: nil, codeBlockID: nil) }
        guard let code = try await children(of: toggleID).first(where: { $0["type"] as? String == "code" }),
              let codeID = code["id"] as? String
        else { return Loaded(settings: nil, codeBlockID: nil) }
        let text = Self.plainText((code["code"] as? [String: Any])?["rich_text"])
        // A hand-edit that broke the JSON reads as "no settings"; the next save repairs it.
        return Loaded(settings: try? SharedSettings.decode(text), codeBlockID: codeID)
    }

    /// Writes `settings`, creating the toggle on first use. Returns the code block ID.
    @discardableResult
    public func save(_ settings: SharedSettings, codeBlockID: String?) async throws -> String {
        let code: [String: Any] = ["language": "json", "rich_text": Self.richText(try settings.json())]
        if let codeBlockID {
            _ = try await transport.api("/v1/blocks/\(codeBlockID)", method: "PATCH", body: ["code": code])
            return codeBlockID
        }
        let data = try await transport.api("/v1/blocks/\(rootPageID)/children", method: "PATCH", body: [
            "children": [[
                "type": "toggle",
                "toggle": [
                    "rich_text": [["type": "text", "text": ["content": Self.toggleTitle]]],
                    "color": "gray",
                    "children": [
                        ["type": "paragraph", "paragraph": ["rich_text": [["type": "text", "text": [
                            "content": "Projects and schedule shared by YATD on all your Macs. Edited by the app.",
                        ]]]]],
                        ["type": "code", "code": code],
                    ],
                ],
            ]],
        ])
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let toggleID = (root["results"] as? [[String: Any]])?.first(where: isSettingsToggle)?["id"] as? String,
              let codeID = try await children(of: toggleID).first(where: { $0["type"] as? String == "code" })?["id"] as? String
        else { throw NotionError.unexpectedResponse(String(decoding: data, as: UTF8.self)) }
        return codeID
    }

    private func isSettingsToggle(_ block: [String: Any]) -> Bool {
        block["type"] as? String == "toggle"
            && Self.plainText((block["toggle"] as? [String: Any])?["rich_text"]) == Self.toggleTitle
    }

    private func children(of blockID: String) async throws -> [[String: Any]] {
        var all: [[String: Any]] = []
        var cursor: String?
        repeat {
            let path = "/v1/blocks/\(blockID)/children?page_size=100" + (cursor.map { "&start_cursor=\($0)" } ?? "")
            let data = try await transport.api(path, method: "GET")
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw NotionError.unexpectedResponse(String(decoding: data, as: UTF8.self))
            }
            all += root["results"] as? [[String: Any]] ?? []
            cursor = (root["has_more"] as? Bool == true) ? root["next_cursor"] as? String : nil
        } while cursor != nil
        return all
    }

    static func plainText(_ richText: Any?) -> String {
        (richText as? [[String: Any]] ?? []).compactMap { $0["plain_text"] as? String }.joined()
    }

    /// Notion caps each rich text item at 2000 characters, so long JSON is split across items.
    static func richText(_ text: String, chunk: Int = 2000) -> [[String: Any]] {
        var items: [[String: Any]] = []
        var rest = Substring(text)
        while !rest.isEmpty {
            let piece = rest.prefix(chunk)
            items.append(["type": "text", "text": ["content": String(piece)]])
            rest = rest.dropFirst(piece.count)
        }
        return items.isEmpty ? [["type": "text", "text": ["content": ""]]] : items
    }
}
