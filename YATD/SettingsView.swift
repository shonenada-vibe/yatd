import ServiceManagement
import SwiftUI
import YATDCore

struct SettingsView: View {
    @Environment(TaskStore.self) private var store
    @AppStorage(Pref.ntnPath) private var ntnPath = ""
    @AppStorage(Pref.alwaysOnTop) private var alwaysOnTop = true
    @AppStorage(Pref.opacity) private var opacity = 1.0
    @AppStorage(Pref.clearGlass) private var clearGlass = false
    @AppStorage(Pref.dayStartHour) private var dayStartHour = 4
    @AppStorage(Pref.reminders) private var reminders = true
    @AppStorage(Pref.pollSeconds) private var pollSeconds = 60
    @State private var connectInput = ""
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section("Notion") {
                if !Pref.isSandboxed {
                    Picker("Connect with", selection: Binding(
                        get: { store.connection },
                        set: { mode in Task { await store.setConnection(mode, token: Keychain.token) } }
                    )) {
                        ForEach(Connection.allCases) { Text($0.label).tag($0) }
                    }
                }
                if store.connection == .token {
                    LabeledContent("Token") {
                        Text(store.hasCredentials ? "Saved in Keychain" : "Not set")
                            .foregroundStyle(.secondary)
                    }
                    TokenSignIn()
                }
                LabeledContent("Data source") {
                    Text(store.config?.dataSourceID ?? "Not connected")
                        .textSelection(.enabled)
                        .font(.caption.monospaced())
                }
                if let url = store.config?.pageURL {
                    Link("Open in Notion", destination: url)
                }
                HStack {
                    TextField("Database URL or ID", text: $connectInput)
                    Button("Connect") { Task { await store.connect(connectInput) } }
                        .disabled(connectInput.isEmpty)
                }
                if store.connection == .ntn {
                    Button("Create a new “YATD” page in Notion") { Task { await store.createDatabase() } }
                }
                if store.connection == .ntn {
                    TextField("ntn path", text: $ntnPath, prompt: Text(NtnCLI.locate()?.executable.path ?? "auto"))
                }
                Stepper("Sync every \(pollSeconds)s", value: $pollSeconds, in: 15...600, step: 15)
            }
            Section("Panel") {
                Toggle("Always on top", isOn: $alwaysOnTop)
                Slider(value: $opacity, in: 0.4...1) { Text("Opacity") }
                if #available(macOS 26.0, *) {
                    Toggle("Clear glass (more see-through)", isOn: $clearGlass)
                }
                Text("Show/hide: ⌥⌘Y").foregroundStyle(.secondary)
            }
            Section("Daily schedule") {
                Picker("New day starts at", selection: $dayStartHour) {
                    ForEach(0..<12) { Text(String(format: "%02d:00", $0)).tag($0) }
                }
                Toggle("Notify when a scheduled task starts", isOn: $reminders)
                    .onChange(of: reminders) { _, on in if on { store.requestNotificationPermission() } }
            }
            Section("General") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            store.error = error.localizedDescription
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }
}
