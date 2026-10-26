import Foundation
import Testing
@testable import YATDCore

@Suite struct SharedSettingsTests {
    let work = Project(dataSourceID: "work", name: "Work")
    let home = Project(dataSourceID: "home", name: "Home")
    let side = Project(dataSourceID: "side", name: "Side")

    @Test func roundTripsThroughJSON() throws {
        let rule = ScheduleRule(weekdays: [2, 3, 4], startMinute: 540, endMinute: 1080, projectIDs: ["work"])
        let settings = SharedSettings(projects: [work, home], rules: [rule], dayStartHour: 5)
        let json = try settings.json()
        #expect(try SharedSettings.decode(json) == settings)
        #expect(json.contains("\"name\" : \"Work\""))
    }

    @Test func firstSyncMergesLocalIntoShared() {
        let sharedRule = ScheduleRule(startMinute: 0, endMinute: 0, projectIDs: ["work"])
        let localRule = ScheduleRule(startMinute: 60, endMinute: 120, projectIDs: ["side"])
        let shared = SharedSettings(projects: [work, home], rules: [sharedRule], dayStartHour: nil)
        let local = SharedSettings(projects: [home, side], rules: [localRule, sharedRule], dayStartHour: 4)
        let merged = shared.merged(withLocal: local)
        #expect(merged.projects.map(\.id) == ["work", "home", "side"])
        #expect(merged.rules.map(\.id) == [sharedRule.id, localRule.id])
        #expect(merged.dayStartHour == 4)
    }

    @Test func splitsLongTextIntoRichTextChunks() {
        let text = String(repeating: "a", count: 4500)
        let items = NotionSettingsDocument.richText(text)
        #expect(items.count == 3)
        let joined = items.compactMap { ($0["text"] as? [String: Any])?["content"] as? String }.joined()
        #expect(joined == text)
    }
}
