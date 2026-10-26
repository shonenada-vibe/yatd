import Foundation
import YATDCore

/// UserDefaults-backed preferences. Views bind to these keys with @AppStorage.
enum Pref {
    static let dataSourceID = "dataSourceID"
    static let pageURL = "pageURL"
    static let ntnPath = "ntnPath"
    static let alwaysOnTop = "alwaysOnTop"
    static let opacity = "opacity"
    static let showPanel = "showPanel"
    static let dayStartHour = "dayStartHour"
    static let reminders = "reminders"
    static let pollSeconds = "pollSeconds"
    static let connection = "connection"
    static let clearGlass = "clearGlass"
    static let showInDock = "showInDock"
    static let panelCollapsed = "panelCollapsed"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            alwaysOnTop: true,
            opacity: 1.0,
            showPanel: true,
            dayStartHour: 4,
            reminders: true,
            pollSeconds: 60,
            showInDock: true,
        ])
    }

    /// The App Store / TestFlight build runs in the App Sandbox, where `ntn` can't be launched.
    static let isSandboxed = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil

    static var connectionMode: Connection {
        get {
            if isSandboxed { return .token }
            return UserDefaults.standard.string(forKey: connection).flatMap(Connection.init(rawValue:)) ?? .ntn
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: connection) }
    }

    static let projectsKey = "projects"
    static let rulesKey = "scheduleRules"
    static let selectionKey = "projectSelection"
    static let rootPageID = "rootPageID"
    static let lastSharedKey = "lastSharedSettings"

    /// The projects shown in YATD, in display order. The single database from before projects
    /// existed becomes the first project.
    static var projects: [Project] {
        get {
            if let list: [Project] = decode(projectsKey) { return list }
            guard let id = UserDefaults.standard.string(forKey: dataSourceID), !id.isEmpty else { return [] }
            let url = UserDefaults.standard.string(forKey: pageURL).flatMap(URL.init(string:))
            return [Project(dataSourceID: id, name: "Tasks", pageURL: url)]
        }
        set { encode(newValue, projectsKey) }
    }

    static var rules: [ScheduleRule] {
        get { decode(rulesKey) ?? [] }
        set { encode(newValue, rulesKey) }
    }

    static var selection: ProjectSelection {
        get { decode(selectionKey) ?? .auto }
        set { encode(newValue, selectionKey) }
    }

    /// The shared settings as this Mac last read or wrote them in Notion; tells local edits
    /// apart from another Mac's.
    static var lastShared: SharedSettings? {
        get { decode(lastSharedKey) }
        set { encode(newValue, lastSharedKey) }
    }

    private static func decode<T: Decodable>(_ key: String) -> T? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    private static func encode<T: Encodable>(_ value: T, _ key: String) {
        UserDefaults.standard.set(try? JSONEncoder().encode(value), forKey: key)
    }
}

/// How YATD reaches Notion.
enum Connection: String, CaseIterable, Identifiable {
    /// The `ntn` CLI and its existing login. Not available in the sandbox.
    case ntn
    /// An internal integration token, stored in Keychain.
    case token

    var id: String { rawValue }
    var label: String {
        switch self {
        case .ntn: "ntn CLI"
        case .token: "Integration token"
        }
    }
}
