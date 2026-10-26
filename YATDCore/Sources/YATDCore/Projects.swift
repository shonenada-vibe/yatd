import Foundation

/// A project is one Notion page holding its own YATD tasks database.
public struct Project: Codable, Sendable, Identifiable, Hashable {
    public var dataSourceID: String
    public var name: String
    public var pageURL: URL?
    public var id: String { dataSourceID }

    public init(dataSourceID: String, name: String, pageURL: URL? = nil) {
        self.dataSourceID = dataSourceID
        self.name = name
        self.pageURL = pageURL
    }

    public init(_ config: SourceConfig, name: String) {
        self.init(dataSourceID: config.dataSourceID, name: name, pageURL: config.pageURL)
    }

    public var config: SourceConfig { SourceConfig(dataSourceID: dataSourceID, pageURL: pageURL) }
}

/// Which projects the panel shows: chosen by the schedule, or picked by hand.
public enum ProjectSelection: Codable, Sendable, Equatable {
    case auto
    case manual([String])
}

/// "Weekdays 09:00–18:00 → Work, Side project". Times are minutes after midnight; an end at or
/// before the start runs past midnight (21:00–02:00), with `weekdays` naming the day it starts.
public struct ScheduleRule: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    /// `Calendar` weekdays, 1 = Sunday … 7 = Saturday. Empty means every day.
    public var weekdays: Set<Int>
    public var startMinute: Int
    public var endMinute: Int
    public var projectIDs: [String]

    public init(id: UUID = UUID(), weekdays: Set<Int> = [], startMinute: Int, endMinute: Int, projectIDs: [String]) {
        self.id = id
        self.weekdays = weekdays
        self.startMinute = startMinute
        self.endMinute = endMinute
        self.projectIDs = projectIDs
    }

    public static let everyDay: Set<Int> = Set(1...7)
    public static let weekdaysOnly: Set<Int> = Set(2...6)
    public static let weekend: Set<Int> = [1, 7]

    public func matches(_ now: Date, calendar: Calendar = .current) -> Bool {
        let c = calendar.dateComponents([.weekday, .hour, .minute], from: now)
        let minute = c.hour! * 60 + c.minute!
        let today = c.weekday!
        let yesterday = today == 1 ? 7 : today - 1
        let days = weekdays.isEmpty ? Self.everyDay : weekdays

        if startMinute == endMinute { return days.contains(today) } // all day
        if startMinute < endMinute {
            return days.contains(today) && minute >= startMinute && minute < endMinute
        }
        // Crosses midnight: the evening part belongs to today, the early hours to yesterday's rule.
        return (days.contains(today) && minute >= startMinute) || (days.contains(yesterday) && minute < endMinute)
    }
}

public struct ProjectScheduler: Sendable {
    public var calendar: Calendar

    public init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    /// The first rule (in list order) that covers `now` and names at least one known project.
    public func matchingRule(_ rules: [ScheduleRule], projects: [Project], now: Date) -> ScheduleRule? {
        let known = Set(projects.map(\.id))
        return rules.first { $0.matches(now, calendar: calendar) && $0.projectIDs.contains(where: known.contains) }
    }

    /// The projects to show now, in the user's project order. Falls back to every project when
    /// nothing is picked or no rule applies, so the panel is never empty for lack of a rule.
    public func activeProjectIDs(_ projects: [Project], rules: [ScheduleRule],
                                 selection: ProjectSelection, now: Date) -> [String] {
        let wanted: Set<String>
        switch selection {
        case .manual(let ids): wanted = Set(ids)
        case .auto: wanted = Set(matchingRule(rules, projects: projects, now: now)?.projectIDs ?? [])
        }
        let active = projects.map(\.id).filter(wanted.contains)
        return active.isEmpty ? projects.map(\.id) : active
    }
}

extension ScheduleRule {
    /// "Mon–Fri 09:00–18:00 · Work, Side Project"
    public func summary(projects: [Project], calendar: Calendar = .current) -> String {
        let names = projects.filter { projectIDs.contains($0.id) }.map(\.name).joined(separator: ", ")
        return "\(daysDescription(calendar)) \(Self.clock(startMinute))–\(Self.clock(endMinute)) · \(names)"
    }

    public func daysDescription(_ calendar: Calendar = .current) -> String {
        let days = weekdays.isEmpty ? Self.everyDay : weekdays
        if days == Self.everyDay { return "Every day" }
        if days == Self.weekdaysOnly { return "Weekdays" }
        if days == Self.weekend { return "Weekends" }
        let symbols = calendar.shortWeekdaySymbols
        return [2, 3, 4, 5, 6, 7, 1].filter(days.contains).map { symbols[$0 - 1] }.joined(separator: " ")
    }

    static func clock(_ minute: Int) -> String {
        String(format: "%02d:%02d", minute / 60, minute % 60)
    }
}
