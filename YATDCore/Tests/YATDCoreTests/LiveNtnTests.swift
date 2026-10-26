import Foundation
import Testing
@testable import YATDCore

/// Hits real Notion through `ntn`. Run with:
///   YATD_LIVE_DS=<data source id> swift test --filter LiveNtnTests
@Suite(.enabled(if: ProcessInfo.processInfo.environment["YATD_LIVE_DS"] != nil))
struct LiveNtnTests {
    @Test func createCompleteRecurAndClean() async throws {
        let ds = ProcessInfo.processInfo.environment["YATD_LIVE_DS"]!
        let cli = try #require(NtnCLI.locate())
        let source = NotionSource(dataSourceID: ds, transport: cli)
        let planner = Planner()
        let today = planner.today(.now)

        let draft = try #require(QuickAdd.parse("yatd-live-test @9:00-9:30 *daily", today: today))
        let created = try await source.create(draft)
        #expect(created.title == "yatd-live-test")
        #expect(created.date == draft.date)

        var cleanup = [created.id]
        defer {
            let ids = cleanup
            Task { for id in ids { _ = try? await cli.api("/v1/pages/\(id)", method: "PATCH", body: ["in_trash": true]) } }
        }

        #expect(try await source.fetchOpen().contains { $0.id == created.id })

        try await source.ensureSchema()
        try await source.update(created.id, created.completeChanges(now: .now))
        let next = try #require(planner.nextInstance(after: created, now: .now))
        #expect(!planner.alreadyScheduled(next, in: try await source.openTasks(titled: next.title)))
        let nextCreated = try await source.create(next)
        cleanup.append(nextCreated.id)
        // A second Mac completing the same task now sees the copy and doesn't create another.
        #expect(planner.alreadyScheduled(next, in: try await source.openTasks(titled: next.title)))

        let discovered = try await NotionSource.discover(transport: cli)
        #expect(discovered.contains { $0.config.dataSourceID == ds })

        #expect(try await source.fetchDone(on: today).contains { $0.id == created.id })
        let open = try await source.fetchOpen()
        #expect(!open.contains { $0.id == created.id })
        let tomorrow = try #require(open.first { $0.id == nextCreated.id })
        #expect(Calendar.current.isDate(tomorrow.date!.start, inSameDayAs: Calendar.current.date(byAdding: .day, value: 1, to: today)!))
        #expect(tomorrow.repeat == .daily)

        for id in cleanup { _ = try await cli.api("/v1/pages/\(id)", method: "PATCH", body: ["in_trash": true]) }
        cleanup = []
    }
}

/// Creates a throwaway project page under the YATD page, then trashes it.
///   YATD_LIVE_DS=<data source id> swift test --filter LiveProjectTests
@Suite(.enabled(if: ProcessInfo.processInfo.environment["YATD_LIVE_DS"] != nil))
struct LiveProjectTests {
    @Test func createProjectAddTaskAndClean() async throws {
        let ds = ProcessInfo.processInfo.environment["YATD_LIVE_DS"]!
        let cli = try #require(NtnCLI.locate())

        // The original Tasks database lives directly in the YATD page.
        let root = try #require(try await NotionSource(dataSourceID: ds, transport: cli).metadata().parentPageID)
        let name = "yatd-live-project-\(Int.random(in: 1000...9999))"
        let project = try await NotionSource.createProject(named: name, parentPageID: root, transport: cli)
        let pageID = try #require(project.pageURL.flatMap { NotionCoding.extractID($0.absoluteString) })
        defer { Task { _ = try? await cli.api("/v1/pages/\(pageID)", method: "PATCH", body: ["in_trash": true]) } }

        #expect(project.name == name)
        let source = NotionSource(dataSourceID: project.id, transport: cli)
        let meta = try await source.metadata()
        #expect(meta.title == name)
        #expect(meta.parentPageID == pageID)
        // A project page is named like its database and sits in the YATD page.
        let page = try await NotionSource.pageInfo(pageID, transport: cli)
        #expect(page.title == name && page.parentPageID == root)

        let draft = try #require(QuickAdd.parse("first task #\(name)", today: Planner().today(.now), projects: [project]))
        #expect(draft.projectID == project.id)
        let created = try await source.create(draft)
        #expect(created.projectID == project.id)
        #expect(try await source.fetchOpen().map(\.id) == [created.id])

        _ = try await cli.api("/v1/pages/\(pageID)", method: "PATCH", body: ["in_trash": true])
    }
}

/// Writes and re-reads the shared settings block on a throwaway page, then trashes it.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["YATD_LIVE_DS"] != nil))
struct LiveSettingsTests {
    @Test func saveLoadUpdate() async throws {
        let ds = ProcessInfo.processInfo.environment["YATD_LIVE_DS"]!
        let cli = try #require(NtnCLI.locate())
        let root = try #require(try await NotionSource(dataSourceID: ds, transport: cli).metadata().parentPageID)
        let pageData = try await cli.api("/v1/pages", method: "POST", body: [
            "parent": ["type": "page_id", "page_id": root],
            "properties": ["title": ["title": [["text": ["content": "yatd-live-settings"]]]]],
        ])
        let pageID = try #require((try JSONSerialization.jsonObject(with: pageData) as? [String: Any])?["id"] as? String)
        defer { Task { _ = try? await cli.api("/v1/pages/\(pageID)", method: "PATCH", body: ["in_trash": true]) } }

        let doc = NotionSettingsDocument(rootPageID: pageID, transport: cli)
        #expect(try await doc.load().settings == nil)

        // Long enough to need several rich text chunks.
        let projects = (1...40).map { Project(dataSourceID: "ds-\($0)", name: "Project number \($0) with a long name") }
        var settings = SharedSettings(projects: projects,
                                      rules: [ScheduleRule(weekdays: [2, 6], startMinute: 1260, endMinute: 120, projectIDs: ["ds-1"])],
                                      dayStartHour: 4)
        #expect(try settings.json().count > 2000)
        let blockID = try await doc.save(settings, codeBlockID: nil)
        var loaded = try await doc.load()
        #expect(loaded.settings == settings)
        #expect(loaded.codeBlockID == blockID)

        settings.dayStartHour = 6
        settings.projects.removeLast(30)
        try await doc.save(settings, codeBlockID: blockID)
        loaded = try await doc.load()
        #expect(loaded.settings == settings)

        _ = try await cli.api("/v1/pages/\(pageID)", method: "PATCH", body: ["in_trash": true])
    }
}
