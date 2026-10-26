import Foundation

/// Where tasks live. `NtnCLISource` today; a direct REST/OAuth source can be added later.
public protocol TaskSource: Sendable {
    /// All tasks that aren't done.
    func fetchOpen() async throws -> [TodoTask]
    /// Done tasks dated today, for progress and the timeline.
    func fetchDone(on day: Date) async throws -> [TodoTask]
    func create(_ task: TodoTask) async throws -> TodoTask
    func setDone(_ id: String, _ done: Bool) async throws
    func setDate(_ id: String, _ date: TaskDate?) async throws
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
