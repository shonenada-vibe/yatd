import Foundation

/// Pure scheduling rules: which tasks to show, how recurring tasks advance, what rolls over.
public struct Planner: Sendable {
    public var calendar: Calendar
    /// A timed task enters the top list this long before it starts.
    public var leadTime: TimeInterval
    /// The day starts at this hour; before it, "today" still means yesterday.
    public var dayStartHour: Int

    public init(calendar: Calendar = .current, leadTime: TimeInterval = 60 * 60, dayStartHour: Int = 4) {
        self.calendar = calendar
        self.leadTime = leadTime
        self.dayStartHour = dayStartHour
    }

    // MARK: Day boundaries

    /// Local midnight of the logical day containing `now` (shifted by `dayStartHour`).
    public func today(_ now: Date) -> Date {
        let shifted = calendar.date(byAdding: .hour, value: -dayStartHour, to: now)!
        return calendar.startOfDay(for: shifted)
    }

    func dayStart(_ now: Date) -> Date { today(now) }
    func dayEnd(_ now: Date) -> Date { calendar.date(byAdding: .day, value: 1, to: today(now))! }

    // MARK: Ranking

    public enum Bucket: Int, Comparable, Sendable {
        /// A one-time task you pressed Start on and haven't finished.
        case inProgress = 0
        /// Timed today and started, or starting within `leadTime`.
        case now
        /// Dated before today, not done.
        case overdue
        /// All-day today.
        case today
        /// Timed later today.
        case later
        /// No date.
        case someday

        public static func < (a: Bucket, b: Bucket) -> Bool { a.rawValue < b.rawValue }
    }

    /// `nil` means the task isn't relevant today (done, or dated in the future).
    public func bucket(_ task: TodoTask, now: Date) -> Bucket? {
        if task.done { return nil }
        if task.isRunning(at: now) { return .inProgress }
        let start = dayStart(now), end = dayEnd(now)
        if let date = task.date, date.hasTime {
            if date.start >= end { return nil }
            if date.start < start { return .overdue }
            return date.start.timeIntervalSince(now) <= leadTime ? .now : .later
        }
        // An all-day task's day comes from its date, or else from its planned start.
        guard let dayDate = task.date?.start ?? task.plannedStart else { return .someday }
        let day = calendar.startOfDay(for: dayDate)
        if day >= end { return nil }
        if day < start { return .overdue }
        // A plan for today makes it behave like a timed task.
        if let planned = scheduledStart(task, now: now) {
            return planned.timeIntervalSince(now) <= leadTime ? .now : .later
        }
        return .today
    }

    /// The time a task is set for today: its time block, else its planned start (if today).
    public func scheduledStart(_ task: TodoTask, now: Date) -> Date? {
        if let date = task.date, date.hasTime { return date.start }
        guard let planned = task.plannedStart, planned >= dayStart(now), planned < dayEnd(now) else { return nil }
        return planned
    }

    /// All tasks for today, ordered by importance.
    public func ranked(_ tasks: [TodoTask], now: Date) -> [TodoTask] {
        tasks
            .compactMap { t in bucket(t, now: now).map { (t, $0) } }
            .sorted { a, b in
                if a.1 != b.1 { return a.1 < b.1 }
                if a.1 == .inProgress { return a.0.startedAt! < b.0.startedAt! }
                if a.1 == .now || a.1 == .later,
                   let sa = scheduledStart(a.0, now: now), let sb = scheduledStart(b.0, now: now), sa != sb {
                    return sa < sb
                }
                let pa = a.0.priority?.rank ?? 2, pb = b.0.priority?.rank ?? 2
                if pa != pb { return pa < pb }
                let oa = a.0.order ?? .greatestFiniteMagnitude, ob = b.0.order ?? .greatestFiniteMagnitude
                if oa != ob { return oa < ob }
                return a.0.createdTime < b.0.createdTime
            }
            .map(\.0)
    }

    public func top(_ tasks: [TodoTask], now: Date, limit: Int = 3) -> [TodoTask] {
        Array(ranked(tasks, now: now).prefix(limit))
    }

    /// Tasks with a time today, in time order, for the timeline view. Includes done ones.
    /// Tasks with a time today (time block or planned start), in time order, for the timeline
    /// view. Includes done ones.
    public func timeline(_ tasks: [TodoTask], now: Date) -> [TodoTask] {
        let start = dayStart(now), end = dayEnd(now)
        return tasks
            .compactMap { t in scheduledStart(t, now: now).map { (t, $0) } }
            .filter { $0.1 >= start && $0.1 < end }
            .sorted { $0.1 < $1.1 }
            .map(\.0)
    }

    /// `time`'s time of day on `day`.
    func sameTime(_ time: Date, on day: Date) -> Date {
        let c = calendar.dateComponents([.hour, .minute, .second], from: time)
        return calendar.date(bySettingHour: c.hour!, minute: c.minute!, second: c.second!, of: day) ?? time
    }

    // MARK: Recurrence

    /// The first occurrence of `rule` strictly after the day of `date`, keeping the time of day.
    public func nextOccurrence(of date: Date, rule: Repeat) -> Date {
        var next = calendar.date(byAdding: .day, value: 1, to: date)!
        if rule == .weekdays {
            while calendar.isDateInWeekend(next) {
                next = calendar.date(byAdding: .day, value: 1, to: next)!
            }
        }
        return next
    }

    /// Moves `date` onto the earliest occurrence of `rule` on or after `day`, keeping time and duration.
    public func moved(_ date: TaskDate, ontoOrAfter day: Date, rule: Repeat) -> TaskDate {
        var start = date.start
        while calendar.startOfDay(for: start) < day {
            start = nextOccurrence(of: start, rule: rule)
        }
        let shift = start.timeIntervalSince(date.start)
        return TaskDate(start: start, end: date.end.map { $0.addingTimeInterval(shift) }, hasTime: date.hasTime)
    }

    /// The copy to create when a recurring task is completed.
    public func nextInstance(after task: TodoTask, now: Date) -> TodoTask? {
        guard let rule = task.repeat else { return nil }
        let base = task.date ?? TaskDate(start: today(now), hasTime: false)
        // The next one is due the day after the later of its own date and today.
        let from = max(calendar.startOfDay(for: base.start), today(now))
        let target = calendar.date(byAdding: .day, value: 1, to: from)!
        var next = task
        next.id = ""
        next.done = false
        next.startedAt = nil
        next.finishedAt = nil
        next.date = moved(base, ontoOrAfter: target, rule: rule)
        // Same planned time of day on the new day.
        next.plannedStart = task.plannedStart.map { sameTime($0, on: next.date!.start) }
        return next
    }

    /// Whether an open copy of a recurring task already exists on `next`'s day,
    /// e.g. because another Mac completed the same task and created it first.
    public func alreadyScheduled(_ next: TodoTask, in existing: [TodoTask]) -> Bool {
        existing.contains { isSameOccurrence($0, next) }
    }

    /// Extra copies of the same recurring occurrence, keeping the oldest. These come from two Macs
    /// completing the same task at once; the caller trashes them.
    public func duplicates(_ tasks: [TodoTask]) -> [TodoTask] {
        var kept: [TodoTask] = []
        var extra: [TodoTask] = []
        for task in tasks.sorted(by: { $0.createdTime < $1.createdTime }) {
            if !task.done, task.repeat != nil, kept.contains(where: { isSameOccurrence($0, task) }) {
                extra.append(task)
            } else {
                kept.append(task)
            }
        }
        return extra
    }

    private func isSameOccurrence(_ a: TodoTask, _ b: TodoTask) -> Bool {
        guard !a.done, !b.done, a.id != b.id,
              a.title == b.title, a.repeat != nil, a.repeat == b.repeat,
              let da = a.date, let db = b.date, da.hasTime == db.hasTime
        else { return false }
        return da.hasTime ? da.start == db.start : calendar.isDate(da.start, inSameDayAs: db.start)
    }

    /// Recurring tasks left undone on a past day jump forward to today (or the next valid weekday),
    /// instead of piling up as overdue.
    public func rollovers(_ tasks: [TodoTask], now: Date) -> [(task: TodoTask, newDate: TaskDate)] {
        let start = dayStart(now)
        return tasks.compactMap { t in
            guard !t.done, let rule = t.repeat, let d = t.date, calendar.startOfDay(for: d.start) < start else { return nil }
            return (t, moved(d, ontoOrAfter: start, rule: rule))
        }
    }

    /// The writes for a rollover: the new date, and the plan moved to the same time that day.
    public func rolloverChanges(_ task: TodoTask, newDate: TaskDate) -> [TaskChange] {
        var changes: [TaskChange] = [.date(newDate)]
        if let planned = task.plannedStart { changes.append(.plannedStart(sameTime(planned, on: newDate.start))) }
        return changes
    }

    /// Unstarted one-time tasks this long past their planned start are shown as late.
    public static let lateAfter: TimeInterval = 10 * 60

    public func isLate(_ task: TodoTask, now: Date) -> Bool {
        guard !task.done, task.startedAt == nil, let planned = scheduledStart(task, now: now),
              task.date?.hasTime != true else { return false }
        return now.timeIntervalSince(planned) > Self.lateAfter
    }
}

// MARK: Time tracking

extension TodoTask {
    /// Started and not finished. Only one-time tasks track time, and a start in the future
    /// (bad data, clock changes) doesn't count.
    public func isRunning(at now: Date) -> Bool {
        guard tracksTime, !done, let startedAt else { return false }
        return startedAt <= now
    }

    /// Changes for pressing Start: one-time tasks only, and only once.
    public func startChanges(now: Date) -> [TaskChange] {
        guard tracksTime, !done, startedAt == nil else { return [] }
        return [.startedAt(now)]
    }

    /// Marking done records when a one-time task finished.
    public func completeChanges(now: Date) -> [TaskChange] {
        tracksTime ? [.done(true), .finishedAt(now)] : [.done(true)]
    }

    /// Reopening clears the finish time but keeps the start.
    public func reopenChanges() -> [TaskChange] {
        tracksTime ? [.done(false), .finishedAt(nil)] : [.done(false)]
    }

    public func applying(_ changes: [TaskChange]) -> TodoTask {
        var t = self
        for change in changes {
            switch change {
            case .done(let d): t.done = d
            case .date(let d): t.date = d
            case .startedAt(let d): t.startedAt = d
            case .finishedAt(let d): t.finishedAt = d
            case .plannedStart(let d): t.plannedStart = d
            }
        }
        return t
    }
}
