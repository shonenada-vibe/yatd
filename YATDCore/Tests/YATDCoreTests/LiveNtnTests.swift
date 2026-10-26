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
        let source = NtnCLISource(dataSourceID: ds, cli: cli)
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

        try await source.setDone(created.id, true)
        let next = try #require(planner.nextInstance(after: created, now: .now))
        let nextCreated = try await source.create(next)
        cleanup.append(nextCreated.id)

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
