import Foundation
import Testing
@testable import YATDCore

private let cal: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    return c
}()

private func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
    cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
}

private let work = Project(dataSourceID: "work", name: "Work")
private let side = Project(dataSourceID: "side", name: "Side Project")
private let home = Project(dataSourceID: "home", name: "Home")
private let projects = [work, side, home]

// 2026-10-26 is a Monday; 2026-10-31 a Saturday.
private let daytime = ScheduleRule(weekdays: ScheduleRule.weekdaysOnly, startMinute: 9 * 60, endMinute: 18 * 60,
                                   projectIDs: ["work", "side"])
private let nighttime = ScheduleRule(weekdays: [], startMinute: 21 * 60, endMinute: 2 * 60, projectIDs: ["home"])

@Suite struct ScheduleRuleTests {
    @Test func dayRuleCoversWeekdayHoursOnly() {
        #expect(daytime.matches(at(2026, 10, 26, 9, 0), calendar: cal))
        #expect(daytime.matches(at(2026, 10, 26, 17, 59), calendar: cal))
        #expect(!daytime.matches(at(2026, 10, 26, 18, 0), calendar: cal))   // end is exclusive
        #expect(!daytime.matches(at(2026, 10, 31, 10, 0), calendar: cal))   // Saturday
    }

    @Test func nightRuleCrossesMidnight() {
        #expect(nighttime.matches(at(2026, 10, 26, 23, 0), calendar: cal))
        #expect(nighttime.matches(at(2026, 10, 27, 1, 30), calendar: cal))
        #expect(!nighttime.matches(at(2026, 10, 27, 2, 0), calendar: cal))
        #expect(!nighttime.matches(at(2026, 10, 27, 20, 0), calendar: cal))
    }

    @Test func overnightRuleBelongsToTheDayItStarts() {
        // Friday-night only: covers Fri 22:00 → Sat 03:00, not Thu night or Sat night.
        let friday = ScheduleRule(weekdays: [6], startMinute: 22 * 60, endMinute: 3 * 60, projectIDs: ["home"])
        #expect(friday.matches(at(2026, 10, 30, 23), calendar: cal))
        #expect(friday.matches(at(2026, 10, 31, 2), calendar: cal))
        #expect(!friday.matches(at(2026, 10, 30, 2), calendar: cal))
        #expect(!friday.matches(at(2026, 10, 31, 23), calendar: cal))
    }

    @Test func equalStartAndEndMeansAllDay() {
        let weekend = ScheduleRule(weekdays: ScheduleRule.weekend, startMinute: 0, endMinute: 0, projectIDs: ["home"])
        #expect(weekend.matches(at(2026, 10, 31, 15), calendar: cal))
        #expect(!weekend.matches(at(2026, 10, 30, 15), calendar: cal))
    }
}

@Suite struct ProjectSchedulerTests {
    let scheduler = ProjectScheduler(calendar: cal)
    let rules = [daytime, nighttime]

    @Test func autoFollowsTheSchedule() {
        #expect(scheduler.activeProjectIDs(projects, rules: rules, selection: .auto, now: at(2026, 10, 26, 10)) == ["work", "side"])
        #expect(scheduler.activeProjectIDs(projects, rules: rules, selection: .auto, now: at(2026, 10, 26, 22)) == ["home"])
    }

    @Test func noMatchingRuleShowsEverything() {
        #expect(scheduler.activeProjectIDs(projects, rules: rules, selection: .auto, now: at(2026, 10, 26, 19)) == ["work", "side", "home"])
        #expect(scheduler.activeProjectIDs(projects, rules: [], selection: .auto, now: .now) == ["work", "side", "home"])
    }

    @Test func firstMatchingRuleWins() {
        let override = ScheduleRule(weekdays: [], startMinute: 12 * 60, endMinute: 13 * 60, projectIDs: ["home"])
        #expect(scheduler.activeProjectIDs(projects, rules: [override] + rules, selection: .auto, now: at(2026, 10, 26, 12, 30)) == ["home"])
        #expect(scheduler.activeProjectIDs(projects, rules: rules + [override], selection: .auto, now: at(2026, 10, 26, 12, 30)) == ["work", "side"])
    }

    @Test func rulesForRemovedProjectsAreSkipped() {
        let stale = ScheduleRule(weekdays: [], startMinute: 0, endMinute: 0, projectIDs: ["gone"])
        #expect(scheduler.activeProjectIDs(projects, rules: [stale, daytime], selection: .auto, now: at(2026, 10, 26, 10)) == ["work", "side"])
    }

    @Test func manualSelectionKeepsProjectOrder() {
        #expect(scheduler.activeProjectIDs(projects, rules: rules, selection: .manual(["home", "work"]), now: at(2026, 10, 26, 10)) == ["work", "home"])
        #expect(scheduler.activeProjectIDs(projects, rules: rules, selection: .manual(["gone"]), now: .now) == ["work", "side", "home"])
    }

    @Test func quickAddPicksProjectByPrefix() {
        let t = QuickAdd.parse("Fix bug #side !h", today: at(2026, 10, 26), calendar: cal, projects: projects)
        #expect(t?.title == "Fix bug")
        #expect(t?.projectID == "side")
        #expect(QuickAdd.parse("Call #SideProject", today: at(2026, 10, 26), calendar: cal, projects: projects)?.projectID == "side")
        // Unknown tags stay in the title.
        let u = QuickAdd.parse("Read #book", today: at(2026, 10, 26), calendar: cal, projects: projects)
        #expect(u?.title == "Read #book" && u?.projectID == nil)
    }
}
