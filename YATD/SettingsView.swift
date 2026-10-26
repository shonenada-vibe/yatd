import ServiceManagement
import SwiftUI
import YATDCore

struct SettingsView: View {
    @AppStorage("settingsTab") private var tab = "general"

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag("general")
            ProjectsSettings()
                .tabItem { Label("Projects", systemImage: "folder") }
                .tag("projects")
            ScheduleSettings()
                .tabItem { Label("Schedule", systemImage: "clock") }
                .tag("schedule")
        }
        .frame(width: 520)
    }
}

// MARK: - General

struct GeneralSettings: View {
    @Environment(TaskStore.self) private var store
    @AppStorage(Pref.ntnPath) private var ntnPath = ""
    @AppStorage(Pref.alwaysOnTop) private var alwaysOnTop = true
    @AppStorage(Pref.opacity) private var opacity = 1.0
    @AppStorage(Pref.clearGlass) private var clearGlass = false
    @AppStorage(Pref.showInDock) private var showInDock = true
    @AppStorage(Pref.dayStartHour) private var dayStartHour = 4
    @AppStorage(Pref.reminders) private var reminders = true
    @AppStorage(Pref.pollSeconds) private var pollSeconds = 60
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
                .onChange(of: dayStartHour) { store.sharedSettingsChanged() }
                Toggle("Notify when a scheduled task starts", isOn: $reminders)
                    .onChange(of: reminders) { _, on in if on { store.requestNotificationPermission() } }
            }
            Section("General") {
                Toggle("Show in Dock", isOn: $showInDock)
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
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Projects

struct ProjectsSettings: View {
    @Environment(TaskStore.self) private var store
    @State private var newName = ""
    @State private var connectInput = ""
    @State private var creating = false

    var body: some View {
        Form {
            Section {
                List {
                    ForEach(store.projects) { project in
                        HStack {
                            Image(systemName: "folder")
                                .foregroundStyle(.secondary)
                            Text(project.name)
                            Spacer()
                            if let url = project.pageURL {
                                Link(destination: url) { Image(systemName: "arrow.up.right.square") }
                                    .help("Open in Notion")
                            }
                            Button(role: .destructive) {
                                store.removeProject(project.id)
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .help("Remove from YATD (the page stays in Notion)")
                        }
                    }
                    .onMove { store.moveProjects(from: $0, to: $1) }
                }
                .frame(minHeight: 120)
            } header: {
                Text("Projects")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Each project is a Notion page with its own tasks. Drag to reorder: quick add uses the first active project unless you type #name.")
                    if let status = store.sharedSettingsStatus { Text(status) }
                }
                .foregroundStyle(.secondary)
            }

            Section("New project") {
                HStack {
                    TextField("Name", text: $newName, prompt: Text("e.g. Side Project"))
                        .onSubmit(create)
                    Button(creating ? "Creating…" : "Create Page", action: create)
                        .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty || creating)
                }
                Text("Creates a page with a tasks database inside your YATD page in Notion.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Add existing") {
                if store.isDiscovering {
                    ProgressView().controlSize(.small)
                } else if store.addableDatabases.isEmpty {
                    Button("Search Notion for YATD databases") { Task { await store.discover() } }
                } else {
                    ForEach(store.addableDatabases) { db in
                        HStack {
                            Text(db.title)
                            Spacer()
                            Button("Add") { Task { await store.connect(db) } }
                        }
                    }
                }
                HStack {
                    TextField("Database URL or ID", text: $connectInput)
                    Button("Add") { Task { await store.connect(connectInput); connectInput = "" } }
                        .disabled(connectInput.isEmpty)
                }
            }
        }
        .formStyle(.grouped)
        .frame(height: 520)
        .task { if store.discovered == nil { await store.discover() } }
    }

    private func create() {
        let name = newName
        creating = true
        Task {
            await store.createProject(named: name)
            creating = false
            if store.error == nil { newName = "" }
        }
    }
}

// MARK: - Schedule

struct ScheduleSettings: View {
    @Environment(TaskStore.self) private var store

    var body: some View {
        Form {
            Section {
                if store.rules.isEmpty {
                    Text("No rules yet: every project shows all the time.")
                        .foregroundStyle(.secondary)
                }
                ForEach(Array(store.rules.enumerated()), id: \.element.id) { index, rule in
                    RuleEditor(rule: binding(for: rule.id), index: index, count: store.rules.count,
                               move: { move(rule.id, by: $0) },
                               delete: { store.setRules(store.rules.filter { $0.id != rule.id }) })
                }
                HStack {
                    Button("Add Daytime Rule") {
                        add(ScheduleRule(weekdays: ScheduleRule.weekdaysOnly, startMinute: 9 * 60, endMinute: 18 * 60, projectIDs: []))
                    }
                    Button("Add Evening Rule") {
                        add(ScheduleRule(weekdays: [], startMinute: 19 * 60, endMinute: 1 * 60, projectIDs: []))
                    }
                }
            } header: {
                Text("Switch projects by time")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("In Auto mode the first matching rule picks the projects; outside every rule, all projects show. A rule ending before it starts runs past midnight. Pick projects by hand from the panel's title menu.")
                    if let status = store.sharedSettingsStatus { Text(status) }
                }
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(height: 520)
    }

    private func add(_ rule: ScheduleRule) {
        var rule = rule
        rule.projectIDs = store.projects.first.map { [$0.id] } ?? []
        store.setRules(store.rules + [rule])
    }

    private func binding(for id: UUID) -> Binding<ScheduleRule> {
        Binding(
            get: { store.rules.first { $0.id == id } ?? ScheduleRule(startMinute: 0, endMinute: 0, projectIDs: []) },
            set: { new in store.setRules(store.rules.map { $0.id == id ? new : $0 }) }
        )
    }

    private func move(_ id: UUID, by offset: Int) {
        var rules = store.rules
        guard let i = rules.firstIndex(where: { $0.id == id }), rules.indices.contains(i + offset) else { return }
        rules.swapAt(i, i + offset)
        store.setRules(rules)
    }
}

struct RuleEditor: View {
    @Environment(TaskStore.self) private var store
    @Binding var rule: ScheduleRule
    let index: Int
    let count: Int
    let move: (Int) -> Void
    let delete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Rule \(index + 1)").font(.headline)
                if store.currentRule?.id == rule.id {
                    Text("Active now")
                        .font(.caption.bold())
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.green.opacity(0.2), in: Capsule())
                }
                Spacer()
                Button { move(-1) } label: { Image(systemName: "chevron.up") }.disabled(index == 0)
                Button { move(1) } label: { Image(systemName: "chevron.down") }.disabled(index == count - 1)
                Button(role: .destructive, action: delete) { Image(systemName: "trash") }
            }
            .buttonStyle(.borderless)

            HStack(spacing: 4) {
                // Monday-first, like most calendars outside the US.
                ForEach([2, 3, 4, 5, 6, 7, 1], id: \.self) { day in
                    let on = rule.weekdays.isEmpty || rule.weekdays.contains(day)
                    Button(Calendar.current.veryShortWeekdaySymbols[day - 1]) { toggle(day) }
                        .buttonStyle(.bordered)
                        .tint(on ? .accentColor : .secondary)
                        .controlSize(.small)
                }
                Spacer()
                DatePicker("From", selection: minuteBinding(\.startMinute), displayedComponents: .hourAndMinute)
                    .labelsHidden()
                Text("–")
                DatePicker("To", selection: minuteBinding(\.endMinute), displayedComponents: .hourAndMinute)
                    .labelsHidden()
            }

            HStack {
                Text("Show").foregroundStyle(.secondary)
                ForEach(store.projects) { project in
                    Toggle(project.name, isOn: Binding(
                        get: { rule.projectIDs.contains(project.id) },
                        set: { on in
                            if on { rule.projectIDs.append(project.id) } else { rule.projectIDs.removeAll { $0 == project.id } }
                        }
                    ))
                    .toggleStyle(.button)
                    .controlSize(.small)
                }
            }
            if rule.endMinute <= rule.startMinute, rule.endMinute != rule.startMinute {
                Text("Runs past midnight into the next day.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func toggle(_ day: Int) {
        var days = rule.weekdays.isEmpty ? ScheduleRule.everyDay : rule.weekdays
        if days.contains(day) { days.remove(day) } else { days.insert(day) }
        // All seven selected is stored as "every day"; none selected isn't allowed.
        rule.weekdays = days == ScheduleRule.everyDay ? [] : (days.isEmpty ? rule.weekdays : days)
    }

    private func minuteBinding(_ key: WritableKeyPath<ScheduleRule, Int>) -> Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(bySettingHour: rule[keyPath: key] / 60, minute: rule[keyPath: key] % 60,
                                      second: 0, of: .now) ?? .now
            },
            set: { date in
                let c = Calendar.current.dateComponents([.hour, .minute], from: date)
                rule[keyPath: key] = c.hour! * 60 + c.minute!
            }
        )
    }
}
