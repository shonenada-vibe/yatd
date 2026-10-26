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
    public var createdTime: Date
    public var url: URL?

    public init(
        id: String,
        title: String,
        done: Bool = false,
        date: TaskDate? = nil,
        priority: Priority? = nil,
        repeat: Repeat? = nil,
        order: Double? = nil,
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

    /// Body for `POST /v1/databases`, creating an inline "Tasks" database under `pageID`.
    public static func createDatabaseBody(parentPageID: String) -> [String: Any] {
        [
            "parent": ["type": "page_id", "page_id": parentPageID],
            "is_inline": true,
            "title": [["text": ["content": "Tasks"]]],
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
                ] as [String: Any],
            ],
        ]
    }
}
