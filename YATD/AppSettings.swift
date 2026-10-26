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
