import SwiftUI
import YATDCore

enum PanelTab: String {
    case top, schedule
}

struct PanelView: View {
    @Environment(TaskStore.self) private var store
    @AppStorage(Pref.alwaysOnTop) private var alwaysOnTop = true
    @AppStorage(Pref.opacity) private var opacity = 1.0
    @AppStorage(Pref.clearGlass) private var clearGlass = false
    @AppStorage("panelTab") private var tab = PanelTab.top
    @AppStorage(Pref.panelCollapsed) private var collapsed = false
    @Namespace private var glass

    var body: some View {
        // One container, so pills added or removed (a task completed, an error shown) morph
        // instead of popping. Its blend distance is below the 10pt row gap so task cards stay
        // separate; only the tighter header buttons melt together.
        GlassGroup(spacing: 8) {
            VStack(alignment: .leading, spacing: 10) {
                if collapsed {
                    collapsedBar
                } else {
                    expanded
                }
                if let error = store.error {
                    Text(error)
                        .font(.caption)
                        .lineLimit(3)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .liquidGlass(in: .rect(cornerRadius: 14), tint: .red.opacity(0.35), interactive: true)
                        .liquidGlassID("error", in: glass)
                        .onTapGesture { store.error = nil }
                        .help("Click to dismiss")
                }
            }
            .animation(.smooth(duration: 0.45), value: store.top.map(\.id))
            .animation(.smooth(duration: 0.45), value: store.error)
            .animation(.smooth(duration: 0.45), value: tab)
            .animation(.smooth(duration: 0.45), value: collapsed)
        }
        // Room for the glass shadows and morphing, which the window would otherwise clip.
        .padding(12)
        .frame(width: 324)
        .environment(\.clearGlass, clearGlass)
        // The panel never becomes key (it mustn't steal focus), and inactive windows render
        // glass tints and accents greyed out. Draw as active so the tints keep their colour.
        .environment(\.controlActiveState, .key)
        .opacity(opacity)
    }

    @ViewBuilder private var expanded: some View {
                header
                if !store.isConfigured || !store.hasCredentials {
                    SetupView()
                        .padding(14)
                        .liquidGlass(in: .rect(cornerRadius: 22))
                        .liquidGlassID("setup", in: glass)
                } else {
                    switch tab {
                    case .top: TopTasksView(glass: glass)
                    case .schedule: ScheduleView(glass: glass)
                    }
                    QuickAddField()
                        .liquidGlassID("add", in: glass)
                }
    }

    /// Minimized: the title, the task that's on top right now, and a restore button. The top
    /// card morphs into the middle pill (same glass ID) and back.
    private var collapsedBar: some View {
        HStack(spacing: 6) {
            titlePill
            if let next = store.top.first {
                Button { collapsed = false } label: {
                    Text(next.title)
                        .font(.callout)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .liquidGlass(in: .capsule, tint: store.planner.bucket(next, now: store.now)?.glassTint, interactive: true)
                .liquidGlassID(next.id, in: glass)
                .help("Restore")
            } else {
                Spacer(minLength: 0)
            }
            Button { collapsed = false } label: {
                Image(systemName: "chevron.down")
            }
            .glassIconButtonStyle()
            .help("Restore panel")
        }
    }

    /// "Today" with one project; otherwise the active project names.
    private var title: String {
        let active = store.activeProjects
        guard store.projects.count > 1, !active.isEmpty else { return "Today" }
        if active.count == store.projects.count { return "All projects" }
        return active.count <= 2 ? active.map(\.name).joined(separator: " + ") : "\(active.count) projects"
    }

    private var titlePill: some View {
        ProjectMenu {
            HStack(spacing: 6) {
                Text(title).font(.headline).lineLimit(1)
                if store.isConfigured {
                    Text("\(store.doneToday.count)/\(store.doneToday.count + store.rankedCount)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }
                if store.projects.count > 1 {
                    Image(systemName: store.selection == .auto ? "clock" : "chevron.down")
                        .font(.caption2.bold())
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Capsule())
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .liquidGlass(in: .capsule)
        .liquidGlassID("title", in: glass)
    }

    private var header: some View {
        HStack(spacing: 6) {
            titlePill

            Spacer(minLength: 0)

            Picker("", selection: $tab) {
                Image(systemName: "list.number").tag(PanelTab.top)
                Image(systemName: "calendar.day.timeline.left").tag(PanelTab.schedule)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Top 3 / Schedule")
            // Close enough to melt into one liquid shape.
            HStack(spacing: 2) {
                Button {
                    Task { await store.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .symbolEffect(.rotate, isActive: store.isSyncing)
                }
                .help(store.lastSync.map { "Synced \($0.formatted(.relative(presentation: .named)))" } ?? "Refresh")
                Button {
                    alwaysOnTop.toggle()
                } label: {
                    Image(systemName: alwaysOnTop ? "pin.fill" : "pin")
                }
                .help(alwaysOnTop ? "Always on top" : "Not pinned")
                Button {
                    collapsed = true
                } label: {
                    Image(systemName: "chevron.up")
                }
                .help("Minimize panel")
            }
            .glassIconButtonStyle()
        }
    }
}

struct TopTasksView: View {
    @Environment(TaskStore.self) private var store
    let glass: Namespace.ID

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if store.top.isEmpty {
                Text(store.lastSync == nil ? "Loading…" : "All clear 🎉")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .liquidGlass(in: .rect(cornerRadius: 18))
                    .liquidGlassID("empty", in: glass)
            }
            ForEach(store.top) { task in
                let bucket = store.planner.bucket(task, now: store.now)
                TaskRow(task: task, bucket: bucket)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .liquidGlass(in: .rect(cornerRadius: 18), tint: bucket?.glassTint, interactive: true)
                    .liquidGlassID(task.id, in: glass)
            }
            let more = store.rankedCount - store.top.count
            if more > 0 {
                Text("+\(more) more today")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .liquidGlass(in: .capsule)
                    .liquidGlassID("more", in: glass)
                    .frame(maxWidth: .infinity)
            }
        }
    }
}

extension Planner.Bucket {
    /// A hint of colour in the glass: running tasks glow with the accent, overdue ones warm.
    var glassTint: Color? {
        switch self {
        case .inProgress: .blue.opacity(0.7)
        case .now: .blue.opacity(0.4)
        case .overdue: .orange.opacity(0.6)
        default: nil
        }
    }
}

struct TaskRow: View {
    @Environment(TaskStore.self) private var store
    let task: TodoTask
    let bucket: Planner.Bucket?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button {
                task.done ? store.reopen(task) : store.complete(task)
            } label: {
                Image(systemName: task.done ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(task.done ? Color.green : priorityColor)
            }
            .buttonStyle(.borderless)

            VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                    .strikethrough(task.done)
                    .foregroundStyle(task.done ? .secondary : .primary)
                    .lineLimit(2)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(bucket == .overdue || late ? .orange : .secondary)
                }
            }
            Spacer(minLength: 0)
            if !task.done {
                Button { editingPlan = true } label: {
                    Image(systemName: task.plannedStart == nil ? "clock" : "clock.fill")
                        .foregroundStyle(late ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                }
                .buttonStyle(.borderless)
                .help(task.plannedStart == nil ? "Plan a start time" : "Change the planned start")
                .popover(isPresented: $editingPlan, arrowEdge: .bottom) {
                    PlanStartEditor(initial: task.plannedStart) { store.setPlannedStart(task, $0) }
                }
            }
            if canStart {
                Button { store.start(task) } label: {
                    Image(systemName: "play.circle")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Start: records the start time in Notion")
            }
        }
        .contentShape(Rectangle())
        .contextMenu {
            if canStart { Button("Start") { store.start(task) } }
            if !task.done { Button(task.plannedStart == nil ? "Plan Start Time…" : "Change Planned Start…") { editingPlan = true } }
            if task.plannedStart != nil, !task.done { Button("Clear Planned Start") { store.setPlannedStart(task, nil) } }
            if let url = task.url { Link("Open in Notion", destination: url) }
        }
    }

    @State private var editingPlan = false

    private var canStart: Bool { !task.startChanges(now: store.now).isEmpty }
    private var late: Bool { store.planner.isLate(task, now: store.now) }

    private var priorityColor: Color {
        switch task.priority {
        case .high: .red
        case .medium: .yellow
        case .low, nil: .secondary
        }
    }

    private var detail: String? {
        var parts: [String] = []
        // Name the project when tasks from several are mixed together.
        if store.activeProjectIDs.count > 1, let project = store.project(task.projectID) {
            parts.append(project.name)
        }
        if let planned = task.plannedStart {
            parts.append(planDescription(planned))
        }
        if let tracked = tracking {
            parts.append(tracked)
        } else if let d = task.date {
            if bucket == .overdue {
                parts.append("Overdue · \(d.start.formatted(.dateTime.month(.abbreviated).day()))")
            } else if d.hasTime {
                parts.append(timeRange(d))
            }
        }
        if let r = task.repeat { parts.append("↻ \(r.rawValue)") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// "Plan 14:30", "Late · plan 14:30", or "Plan Tue 14:30" when it isn't for today.
    private func planDescription(_ planned: Date) -> String {
        let time = planned.formatted(date: .omitted, time: .shortened)
        if late { return "Late · plan \(time)" }
        if store.planner.scheduledStart(task, now: store.now) == nil {
            return "Plan \(planned.formatted(.dateTime.weekday(.abbreviated))) \(time)"
        }
        return "Plan \(time)"
    }

    /// "▶ 10:12 · 25m" while running, "10:12–10:40 · 28m" once finished.
    private var tracking: String? {
        let time = { (d: Date) in d.formatted(date: .omitted, time: .shortened) }
        switch (task.startedAt, task.finishedAt) {
        case let (start?, end?) where task.done:
            return "\(time(start))–\(time(end)) · \(duration(end.timeIntervalSince(start)))"
        case let (nil, end?) where task.done:
            return "Finished \(time(end))"
        case let (start?, _) where task.isRunning(at: store.now):
            return "▶ \(time(start)) · \(duration(store.now.timeIntervalSince(start)))"
        default:
            return nil
        }
    }
}

private func duration(_ seconds: TimeInterval) -> String {
    let minutes = max(0, Int(seconds / 60))
    return minutes < 60 ? "\(minutes)m" : "\(minutes / 60)h \(minutes % 60)m"
}

func timeRange(_ d: TaskDate) -> String {
    let s = d.start.formatted(date: .omitted, time: .shortened)
    guard let end = d.end else { return s }
    return "\(s)–\(end.formatted(date: .omitted, time: .shortened))"
}

struct ScheduleView: View {
    @Environment(TaskStore.self) private var store
    let glass: Namespace.ID

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if store.timeline.isEmpty {
                Text("Nothing scheduled. Add one with @10:00")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .liquidGlass(in: .rect(cornerRadius: 18))
                    .liquidGlassID("empty-schedule", in: glass)
            }
            ForEach(store.timeline) { task in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text((store.planner.scheduledStart(task, now: store.now) ?? .now).formatted(date: .omitted, time: .shortened))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 52, alignment: .trailing)
                    TaskRow(task: task, bucket: store.planner.bucket(task, now: store.now))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .liquidGlass(in: .rect(cornerRadius: 18),
                             tint: isCurrent(task) ? .blue.opacity(0.7) : nil,
                             interactive: true)
                .liquidGlassID("schedule-\(task.id)", in: glass)
                .opacity(task.done ? 0.7 : 1)
            }
        }
    }

    /// Active between start and end; without an end (or for a planned start), for 30 minutes.
    private func isCurrent(_ task: TodoTask) -> Bool {
        guard !task.done, let start = store.planner.scheduledStart(task, now: store.now) else { return false }
        let end = task.date?.hasTime == true ? (task.date?.end ?? start.addingTimeInterval(30 * 60))
                                             : start.addingTimeInterval(30 * 60)
        return start <= store.now && store.now < end
    }
}

struct QuickAddField: View {
    @Environment(TaskStore.self) private var store
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Add task  (^14:30  @10:00  !h  *daily  #project)", text: $text)
            .textFieldStyle(.plain)
            .font(.callout)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .liquidGlass(in: .capsule, interactive: true)
            .focused($focused)
            .onSubmit {
                store.quickAdd(text)
                text = ""
            }
            .onReceive(NotificationCenter.default.publisher(for: .focusQuickAdd)) { _ in focused = true }
    }
}

struct SetupView: View {
    @Environment(TaskStore.self) private var store
    @State private var input = ""

    private var usesToken: Bool { store.connection == .token }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Connect a Notion database").font(.subheadline.bold())
            if !store.hasCredentials {
                TokenSignIn()
            } else {
                found
                Text(usesToken
                     ? "Or paste a database URL, or a page shared with your integration to create YATD inside it:"
                     : "Or paste a database URL (or a page URL to create YATD inside it):")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    TextField("https://notion.so/…", text: $input)
                        .textFieldStyle(.roundedBorder)
                    Button("Connect") { Task { await store.connect(input) } }
                        .glassButtonStyle()
                        .disabled(input.isEmpty)
                }
            }
        }
        .task(id: store.hasCredentials) {
            if store.hasCredentials { await store.discover() }
        }
    }

    @ViewBuilder private var found: some View {
        if store.isDiscovering {
            ProgressView("Looking for an existing YATD database…").controlSize(.small)
        } else if let found = store.discovered {
            if !found.isEmpty {
                Text("Found in your workspace:").font(.caption).foregroundStyle(.secondary)
                ForEach(found) { db in
                    Button {
                        Task { await store.connect(db) }
                    } label: {
                        Label(db.title, systemImage: "checklist")
                    }
                    .glassButtonStyle(prominent: true)
                    .help(db.lastEdited.map { "Edited \($0.formatted(.relative(presentation: .named)))" } ?? "")
                }
                Divider()
            }
            // Integration tokens can't create workspace-level pages; they go through a shared page below.
            if !usesToken {
                Button(found.isEmpty ? "Create “YATD” page in Notion" : "Create a new one instead") {
                    Task { await store.createDatabase() }
                }
                .glassButtonStyle(prominent: found.isEmpty)
            }
        } else {
            // Search failed (error shown below): don't offer Create, it could duplicate.
            Button("Search again") { Task { await store.discover() } }
                .glassButtonStyle()
        }
    }
}

/// Paste-a-token form for the integration-token connection.
struct TokenSignIn: View {
    @Environment(TaskStore.self) private var store
    @State private var token = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Create an internal integration at notion.so/profile/integrations, then share your YATD page with it (••• → Connections).")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Link("Open Notion integrations", destination: URL(string: "https://www.notion.so/profile/integrations")!)
                .font(.caption)
            HStack {
                SecureField("ntn_… integration token", text: $token)
                    .textFieldStyle(.roundedBorder)
                Button("Save") {
                    Task { await store.setConnection(.token, token: token); token = "" }
                }
                .glassButtonStyle(prominent: true)
                .disabled(token.isEmpty)
            }
        }
    }
}

extension Notification.Name {
    static let focusQuickAdd = Notification.Name("YATDFocusQuickAdd")
}

/// The title pill's menu: follow the schedule, or pick projects by hand.
struct ProjectMenu<Label: View>: View {
    @Environment(TaskStore.self) private var store
    @Environment(\.openSettings) private var openSettings
    @ViewBuilder var label: Label

    var body: some View {
        if store.isConfigured {
            Menu {
                Toggle(isOn: Binding(get: { store.selection == .auto }, set: { if $0 { store.setSelection(.auto) } })) {
                    Text("Auto (by schedule)")
                    if let rule = store.currentRule {
                        Text(rule.summary(projects: store.projects))
                    } else if store.selection == .auto {
                        Text(store.rules.isEmpty ? "No rules: all projects" : "No rule now: all projects")
                    }
                }
                Section("Projects") {
                    ForEach(store.projects) { project in
                        Toggle(project.name, isOn: Binding(
                            get: { store.activeProjectIDs.contains(project.id) },
                            set: { _ in store.toggleProject(project.id) }
                        ))
                    }
                }
                Divider()
                Button("New Project…") { open(tab: "projects") }
                Button("Edit Schedule…") { open(tab: "schedule") }
            } label: {
                label
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
        } else {
            label
        }
    }

    private func open(tab: String) {
        UserDefaults.standard.set(tab, forKey: "settingsTab")
        NSApp.activate()
        openSettings()
    }
}

/// Popover for a task's planned start: a time today (or tomorrow if already past), quick picks,
/// and Clear.
struct PlanStartEditor: View {
    let initial: Date?
    let save: (Date?) -> Void
    @State private var time: Date
    @Environment(\.dismiss) private var dismiss

    init(initial: Date?, save: @escaping (Date?) -> Void) {
        self.initial = initial
        self.save = save
        // Default: the next half hour.
        let cal = Calendar.current
        let now = Date.now
        let minute = cal.component(.minute, from: now)
        let next = cal.date(byAdding: .minute, value: minute < 30 ? 30 - minute : 60 - minute, to: now) ?? now
        _time = State(initialValue: initial ?? cal.date(bySetting: .second, value: 0, of: next) ?? next)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Planned start").font(.headline)
            DatePicker("Time", selection: $time, displayedComponents: [.date, .hourAndMinute])
                .datePickerStyle(.stepperField)
                .labelsHidden()
            HStack {
                ForEach([15, 30, 60], id: \.self) { minutes in
                    Button("+\(minutes < 60 ? "\(minutes)m" : "1h")") {
                        time = Date.now.addingTimeInterval(TimeInterval(minutes * 60))
                    }
                }
            }
            .controlSize(.small)
            HStack {
                if initial != nil {
                    Button("Clear", role: .destructive) { save(nil); dismiss() }
                }
                Spacer()
                Button("Set") { save(time); dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 240)
    }
}
