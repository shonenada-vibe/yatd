import Foundation

public enum Priority: String, Codable, Sendable, CaseIterable {
    case high = "High"
    case medium = "Medium"
    case low = "Low"

    /// Lower sorts first. Tasks without a priority sit between Medium and Low.
    var rank: Int {
        switch self {
        case .high: 0
        case .medium: 1
        case .low: 3
        }
    }
}

public enum Repeat: String, Codable, Sendable, CaseIterable {
    case daily = "Daily"
    case weekdays = "Weekdays"
}

/// A Notion date property. All-day dates have `hasTime == false` and `start` at local midnight.
public struct TaskDate: Codable, Sendable, Equatable {
    public var start: Date
    public var end: Date?
    public var hasTime: Bool

    public init(start: Date, end: Date? = nil, hasTime: Bool) {
        self.start = start
        self.end = end
        self.hasTime = hasTime
    }
}

public struct TodoTask: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var title: String
    public var done: Bool
    public var date: TaskDate?
    public var priority: Priority?
    public var `repeat`: Repeat?
    public var order: Double?
    /// When work on a one-time task began / it was completed. Not recorded for recurring tasks.
    public var startedAt: Date?
    public var finishedAt: Date?
    /// When you intend to start, separate from the due day (`date`) and the actual start.
    public var plannedStart: Date?
    public var createdTime: Date
    public var url: URL?
    /// The project (data source) this task came from. Set locally, not stored in Notion.
    public var projectID: String?

    /// One-time tasks get start/finish times recorded.
    public var tracksTime: Bool { `repeat` == nil }

    public init(
        id: String,
        title: String,
        done: Bool = false,
        date: TaskDate? = nil,
        priority: Priority? = nil,
        repeat: Repeat? = nil,
        order: Double? = nil,
        startedAt: Date? = nil,
        finishedAt: Date? = nil,
        createdTime: Date = .now,
        url: URL? = nil
    ) {
        self.id = id
        self.title = title
        self.done = done
        self.date = date
        self.priority = priority
        self.repeat = `repeat`
        self.order = order
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.createdTime = createdTime
        self.url = url
    }
}

/// Property names of the YATD database in Notion.
public enum Schema {
    public static let name = "Name"
    public static let done = "Done"
    public static let date = "Date"
    public static let priority = "Priority"
    public static let `repeat` = "Repeat"
    public static let order = "Order"
    public static let started = "Started"
    public static let finished = "Finished"
    public static let plannedStart = "Plan Start"

    /// Properties added after the first release; `ensureSchema` adds any that an older database lacks.
    public static var addedProperties: [String: [String: Any]] {
        [
            started: ["date": [String: Any]()],
            finished: ["date": [String: Any]()],
            plannedStart: ["date": [String: Any]()],
        ]
    }

    /// Whether a data source's property schema looks like a YATD database.
    public static func matches(properties: [String: Any]) -> Bool {
        let required = [name: "title", done: "checkbox", date: "date", `repeat`: "select"]
        return required.allSatisfy { key, type in
            (properties[key] as? [String: Any])?["type"] as? String == type
        }
    }

    /// Body for `POST /v1/databases`, creating an inline "Tasks" database under `pageID`.
    public static func createDatabaseBody(parentPageID: String, title: String = "Tasks") -> [String: Any] {
        [
            "parent": ["type": "page_id", "page_id": parentPageID],
            "is_inline": true,
            "title": [["text": ["content": title]]],
            "initial_data_source": [
                "properties": [
                    name: ["title": [String: Any]()],
                    done: ["checkbox": [String: Any]()],
                    date: ["date": [String: Any]()],
                    priority: ["select": ["options": [
                        ["name": "High", "color": "red"],
                        ["name": "Medium", "color": "yellow"],
                        ["name": "Low", "color": "gray"],
                    ]]],
                    `repeat`: ["select": ["options": [
                        ["name": "Daily", "color": "blue"],
                        ["name": "Weekdays", "color": "purple"],
                    ]]],
                    order: ["number": ["format": "number"]],
                    started: ["date": [String: Any]()],
                    finished: ["date": [String: Any]()],
                    plannedStart: ["date": [String: Any]()],
                ] as [String: Any],
            ],
        ]
    }
}
