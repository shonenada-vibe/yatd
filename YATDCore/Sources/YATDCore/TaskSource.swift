import Foundation

/// Where tasks live. `NtnCLISource` today; a direct REST/OAuth source can be added later.
public protocol TaskSource: Sendable {
    /// All tasks that aren't done.
    func fetchOpen() async throws -> [TodoTask]
    /// Done tasks dated today, for progress and the timeline.
    func fetchDone(on day: Date) async throws -> [TodoTask]
    /// Open tasks with exactly this title, fetched fresh (another Mac may have just created one).
    func openTasks(titled title: String) async throws -> [TodoTask]
    func create(_ task: TodoTask) async throws -> TodoTask
    /// Moves a task to Notion's trash (recoverable there for 30 days).
    func trash(_ id: String) async throws
    /// Applies all `changes` to one task in a single write.
    func update(_ id: String, _ changes: [TaskChange]) async throws
    /// Adds properties that newer versions of YATD need to an existing database.
    func ensureSchema() async throws
}

public enum TaskChange: Sendable, Equatable {
    case done(Bool)
    case date(TaskDate?)
    case startedAt(Date?)
    case finishedAt(Date?)
}

/// A YATD-shaped database found in the workspace.
public struct DiscoveredDatabase: Sendable, Identifiable, Equatable {
    public var config: SourceConfig
    public var title: String
    public var lastEdited: Date?
    public var id: String { config.dataSourceID }

    public init(config: SourceConfig, title: String, lastEdited: Date?) {
        self.config = config
        self.title = title
        self.lastEdited = lastEdited
    }
}

/// The data source being used, as stored in settings.
public struct SourceConfig: Codable, Sendable, Equatable {
    public var dataSourceID: String
    public var pageURL: URL?

    public init(dataSourceID: String, pageURL: URL? = nil) {
        self.dataSourceID = dataSourceID
        self.pageURL = pageURL
    }
}
