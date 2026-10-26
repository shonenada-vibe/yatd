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

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            alwaysOnTop: true,
            opacity: 1.0,
            showPanel: true,
            dayStartHour: 4,
            reminders: true,
            pollSeconds: 60,
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

    static var sourceConfig: SourceConfig? {
        get {
            let d = UserDefaults.standard
            guard let id = d.string(forKey: dataSourceID), !id.isEmpty else { return nil }
            return SourceConfig(dataSourceID: id, pageURL: d.string(forKey: pageURL).flatMap(URL.init(string:)))
        }
        set {
            let d = UserDefaults.standard
            d.set(newValue?.dataSourceID, forKey: dataSourceID)
            d.set(newValue?.pageURL?.absoluteString, forKey: pageURL)
        }
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
