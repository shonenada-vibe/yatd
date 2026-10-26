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

private func task(_ title: String, _ date: TaskDate? = nil, priority: Priority? = nil,
                  repeat rule: Repeat? = nil, done: Bool = false, order: Double? = nil) -> TodoTask {
    TodoTask(id: title, title: title, done: done, date: date, priority: priority, repeat: rule,
             order: order, createdTime: at(2026, 1, 1))
}

private func allDay(_ d: Date) -> TaskDate { TaskDate(start: d, hasTime: false) }
private func timed(_ s: Date, _ e: Date? = nil) -> TaskDate { TaskDate(start: s, end: e, hasTime: true) }

@Suite struct PlannerTests {
    let planner = Planner(calendar: cal)
    let now = at(2026, 10, 26, 9, 30) // Monday

    @Test func bucketsAndOrder() {
        let tasks = [
            task("someday"),
            task("future", allDay(at(2026, 10, 27))),
            task("done", allDay(at(2026, 10, 26)), done: true),
            task("today-low", allDay(at(2026, 10, 26)), priority: .low),
            task("today-high", allDay(at(2026, 10, 26)), priority: .high),
            task("overdue", allDay(at(2026, 10, 24))),
            task("standup", timed(at(2026, 10, 26, 10), at(2026, 10, 26, 10, 15))),
            task("evening", timed(at(2026, 10, 26, 19))),
        ]
        #expect(planner.ranked(tasks, now: now).map(\.id) ==
                ["standup", "overdue", "today-high", "today-low", "evening", "someday"])
        #expect(planner.top(tasks, now: now).map(\.id) == ["standup", "overdue", "today-high"])
    }

    @Test func orderBreaksTies() {
        let d = allDay(at(2026, 10, 26))
        let tasks = [task("b", d, order: 2), task("a", d, order: 1), task("c", d)]
        #expect(planner.ranked(tasks, now: now).map(\.id) == ["a", "b", "c"])
    }

    @Test func dayStartsAtFourAM() {
        let lateNight = at(2026, 10, 27, 2)
        #expect(planner.today(lateNight) == at(2026, 10, 26))
        // A task for the 27th isn't due yet at 2am on the 27th.
        #expect(planner.bucket(task("x", allDay(at(2026, 10, 27))), now: lateNight) == nil)
        #expect(planner.bucket(task("y", allDay(at(2026, 10, 26))), now: lateNight) == .today)
    }

    @Test func dailyNextInstance() {
        let t = task("read", allDay(at(2026, 10, 26)), repeat: .daily)
        #expect(planner.nextInstance(after: t, now: now)?.date == allDay(at(2026, 10, 27)))
    }

    @Test func weekdaysSkipWeekend() {
        let friday = at(2026, 10, 30, 10)
        let t = task("standup", timed(friday, at(2026, 10, 30, 10, 15)), repeat: .weekdays)
        let next = planner.nextInstance(after: t, now: friday)
        #expect(next?.date == timed(at(2026, 11, 2, 10), at(2026, 11, 2, 10, 15)))
        #expect(next?.done == false)
    }

    @Test func completingOverdueRecurringSchedulesAfterToday() {
        let t = task("read", allDay(at(2026, 10, 20)), repeat: .daily)
        #expect(planner.nextInstance(after: t, now: now)?.date == allDay(at(2026, 10, 27)))
    }

    @Test func rolloverMovesOnlyRecurring() {
        let tasks = [
            task("read", allDay(at(2026, 10, 24)), repeat: .daily),
            task("standup", timed(at(2026, 10, 23, 10)), repeat: .weekdays), // Friday
            task("once", allDay(at(2026, 10, 24))),
            task("todays", allDay(at(2026, 10, 26)), repeat: .daily),
        ]
        let r = planner.rollovers(tasks, now: now)
        #expect(r.map(\.task.id) == ["read", "standup"])
        #expect(r[0].newDate == allDay(at(2026, 10, 26)))
        #expect(r[1].newDate == timed(at(2026, 10, 26, 10)))
    }

    @Test func timelineOnlyTimedToday() {
        let tasks = [
            task("b", timed(at(2026, 10, 26, 15))),
            task("a", timed(at(2026, 10, 26, 8)), done: true),
            task("allday", allDay(at(2026, 10, 26))),
            task("tomorrow", timed(at(2026, 10, 27, 8))),
        ]
        #expect(planner.timeline(tasks, now: now).map(\.id) == ["a", "b"])
    }
}

@Suite struct NotionCodingTests {
    @Test func parsesQueryFixture() throws {
        let url = try #require(Bundle.module.url(forResource: "query", withExtension: "json", subdirectory: "Fixtures"))
        let (tasks, cursor) = try NotionCoding.tasks(fromQueryResponse: Data(contentsOf: url), calendar: cal)
        #expect(cursor == nil)
        #expect(tasks.count == 4)
        let standup = try #require(tasks.first { $0.title == "Standup" })
        #expect(standup.date == timed(at(2026, 10, 26, 10), at(2026, 10, 26, 10, 15)))
        #expect(standup.repeat == .weekdays)
        let read = try #require(tasks.first { $0.title == "Read 20 pages" })
        #expect(read.date == allDay(at(2026, 10, 25)))
        #expect(read.repeat == .daily)
        #expect(read.priority == nil)
        #expect(tasks.first { $0.title == "Try YATD" }?.priority == .high)
    }

    @Test func encodesDates() {
        #expect(NotionCoding.dateString(at(2026, 3, 5), hasTime: false, calendar: cal) == "2026-03-05")
        #expect(NotionCoding.dateString(at(2026, 3, 5, 10), hasTime: true, calendar: cal) == "2026-03-05T10:00:00+08:00")
    }

    @Test func extractsIDs() {
        #expect(NotionCoding.extractID("https://app.notion.com/p/YATD-4052aedebc3781ce9418f8b595563036")
                == "4052aede-bc37-81ce-9418-f8b595563036")
        #expect(NotionCoding.extractID("51fd6f29-fb4a-4ae5-aaaa-7b1e2708f2ef") == "51fd6f29-fb4a-4ae5-aaaa-7b1e2708f2ef")
        #expect(NotionCoding.extractID("nope") == nil)
    }
}

@Suite struct QuickAddTests {
    let today = at(2026, 10, 26)

    @Test func plainTitleIsToday() {
        let t = QuickAdd.parse("Buy milk", today: today, calendar: cal)
        #expect(t?.title == "Buy milk")
        #expect(t?.date == allDay(today))
    }

    @Test func allTokens() {
        let t = QuickAdd.parse("Standup @10:00-10:15 !h *weekdays", today: today, calendar: cal)
        #expect(t?.title == "Standup")
        #expect(t?.date == timed(at(2026, 10, 26, 10), at(2026, 10, 26, 10, 15)))
        #expect(t?.priority == .high)
        #expect(t?.repeat == .weekdays)
    }

    @Test func somedayAndBadTokensStayInTitle() {
        let t = QuickAdd.parse("Email @bob ~ !x", today: today, calendar: cal)
        #expect(t?.title == "Email @bob !x")
        #expect(t?.date == nil)
        #expect(QuickAdd.parse("  !h  ", today: today, calendar: cal) == nil)
    }
}

@Suite struct TimeTrackingTests {
    let now = at(2026, 10, 26, 9, 30)

    @Test func oneTimeTaskRecordsStartAndFinish() {
        let t = task("write", allDay(at(2026, 10, 26)))
        #expect(t.startChanges(now: now) == [.startedAt(now)])
        let started = t.applying(t.startChanges(now: now))
        #expect(started.startChanges(now: now).isEmpty) // only once
        let end = at(2026, 10, 26, 10, 5)
        #expect(started.completeChanges(now: end) == [.done(true), .finishedAt(end)])
        let done = started.applying(started.completeChanges(now: end))
        #expect(done.startedAt == now && done.finishedAt == end && done.done)
        #expect(done.reopenChanges() == [.done(false), .finishedAt(nil)])
        #expect(done.applying(done.reopenChanges()).startedAt == now)
    }

    @Test func recurringTasksRecordNothing() {
        let t = task("read", allDay(at(2026, 10, 26)), repeat: .daily)
        #expect(t.startChanges(now: now).isEmpty)
        #expect(t.completeChanges(now: now) == [.done(true)])
        #expect(t.reopenChanges() == [.done(false)])
    }

    @Test func startedTasksRankFirst() {
        var started = task("started", allDay(at(2026, 10, 27)))
        started.startedAt = at(2026, 10, 26, 9)
        let tasks = [task("standup", timed(at(2026, 10, 26, 10))), started]
        #expect(Planner(calendar: cal).top(tasks, now: now).map(\.id) == ["started", "standup"])
    }

    @Test func encodesChanges() {
        let p = NotionCoding.properties(for: [.done(true), .startedAt(at(2026, 10, 26, 9)), .finishedAt(nil)], calendar: cal)
        #expect((p[Schema.done] as? [String: Bool]) == ["checkbox": true])
        #expect(((p[Schema.started] as? [String: Any])?["date"] as? [String: String]) == ["start": "2026-10-26T09:00:00+08:00"])
        #expect((p[Schema.finished] as? [String: Any])?["date"] is NSNull)
    }
}

@Suite struct MultiMacTests {
    let planner = Planner(calendar: cal)

    private func copy(_ id: String, _ date: TaskDate, created: Date, repeat rule: Repeat? = .daily) -> TodoTask {
        TodoTask(id: id, title: "read", date: date, repeat: rule, createdTime: created)
    }

    @Test func detectsNextCopyAlreadyCreated() {
        let next = TodoTask(id: "", title: "read", date: allDay(at(2026, 10, 27)), repeat: .daily)
        #expect(planner.alreadyScheduled(next, in: [copy("a", allDay(at(2026, 10, 27)), created: .now)]))
        #expect(!planner.alreadyScheduled(next, in: [copy("a", allDay(at(2026, 10, 28)), created: .now)]))
        #expect(!planner.alreadyScheduled(next, in: [copy("a", allDay(at(2026, 10, 27)), created: .now, repeat: nil)]))
    }

    @Test func trashesNewerDuplicatesOnly() {
        let day = allDay(at(2026, 10, 27))
        let tasks = [
            copy("newer", day, created: at(2026, 10, 26, 9, 1)),
            copy("older", day, created: at(2026, 10, 26, 9, 0)),
            copy("other-day", allDay(at(2026, 10, 28)), created: at(2026, 10, 26, 9, 2)),
            copy("one-time", day, created: at(2026, 10, 26, 9, 3), repeat: nil),
            copy("one-time-2", day, created: at(2026, 10, 26, 9, 4), repeat: nil),
        ]
        #expect(planner.duplicates(tasks).map(\.id) == ["newer"])
    }

    @Test func recognisesYATDSchema() {
        func prop(_ type: String) -> [String: Any] { ["type": type] }
        let yatd: [String: Any] = ["Name": prop("title"), "Done": prop("checkbox"), "Date": prop("date"),
                                   "Repeat": prop("select"), "Extra": prop("number")]
        #expect(Schema.matches(properties: yatd))
        var wrong = yatd
        wrong["Done"] = prop("status")
        #expect(!Schema.matches(properties: wrong))
    }
}
