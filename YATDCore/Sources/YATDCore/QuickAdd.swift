import Foundation

/// Parses quick-add text like `Standup @10:00-10:15 !h *weekdays` into a task dated today.
///
/// - `@HH:mm` or `@HH:mm-HH:mm`: time block today
/// - `!h` / `!m` / `!l` (or `!1` / `!2` / `!3`): priority
/// - `*daily` / `*weekdays`: repeat
/// - `~` : no date (someday)
public enum QuickAdd {
    public static func parse(_ text: String, today: Date, calendar: Calendar = .current) -> TodoTask? {
        var words: [String] = []
        var date: TaskDate? = TaskDate(start: today, hasTime: false)
        var priority: Priority?
        var rule: Repeat?

        for token in text.split(separator: " ", omittingEmptySubsequences: true).map(String.init) {
            if token.hasPrefix("@"), let block = timeBlock(String(token.dropFirst()), on: today, calendar: calendar) {
                date = block
            } else if token.hasPrefix("!"), token.count == 2, let p = priorityCode(token.last!) {
                priority = p
            } else if token.hasPrefix("*"), let r = Repeat.allCases.first(where: { $0.rawValue.lowercased() == token.dropFirst().lowercased() }) {
                rule = r
            } else if token == "~" {
                date = nil
            } else {
                words.append(token)
            }
        }
        let title = words.joined(separator: " ")
        guard !title.isEmpty else { return nil }
        return TodoTask(id: "", title: title, date: date, priority: priority, repeat: rule)
    }

    private static func priorityCode(_ c: Character) -> Priority? {
        switch c.lowercased() {
        case "h", "1": .high
        case "m", "2": .medium
        case "l", "3": .low
        default: nil
        }
    }

    private static func timeBlock(_ s: String, on day: Date, calendar: Calendar) -> TaskDate? {
        let parts = s.split(separator: "-", maxSplits: 1).map(String.init)
        guard let start = time(parts[0], on: day, calendar: calendar) else { return nil }
        let end = parts.count == 2 ? time(parts[1], on: day, calendar: calendar) : nil
        if parts.count == 2, end == nil { return nil }
        return TaskDate(start: start, end: end, hasTime: true)
    }

    private static func time(_ s: String, on day: Date, calendar: Calendar) -> Date? {
        let hm = s.split(separator: ":").map { Int($0) }
        guard (1...2).contains(hm.count), let h = hm[0], (0..<24).contains(h) else { return nil }
        let m = hm.count == 2 ? hm[1] : 0
        guard let m, (0..<60).contains(m) else { return nil }
        return calendar.date(bySettingHour: h, minute: m, second: 0, of: day)
    }
}
