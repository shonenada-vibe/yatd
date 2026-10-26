import SwiftUI
import YATDCore

enum PanelTab: String {
    case top, schedule
}

struct PanelView: View {
    @Environment(TaskStore.self) private var store
    @AppStorage(Pref.alwaysOnTop) private var alwaysOnTop = true
    @AppStorage(Pref.opacity) private var opacity = 1.0
    @AppStorage("panelTab") private var tab = PanelTab.top

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if !store.isConfigured || !store.hasCredentials {
                SetupView()
            } else {
                switch tab {
                case .top: TopTasksView()
                case .schedule: ScheduleView()
                }
                QuickAddField()
            }
            if let error = store.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)
                    .onTapGesture { store.error = nil }
            }
        }
        .padding(14)
        .frame(width: 300)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .opacity(opacity)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Today").font(.headline)
            if store.isConfigured {
                Text("\(store.doneToday.count)/\(store.doneToday.count + store.rankedCount)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Picker("", selection: $tab) {
                Image(systemName: "list.number").tag(PanelTab.top)
                Image(systemName: "calendar.day.timeline.left").tag(PanelTab.schedule)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Top 3 / Schedule")
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
        }
        .buttonStyle(.borderless)
    }
}

struct TopTasksView: View {
    @Environment(TaskStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if store.top.isEmpty {
                Text(store.lastSync == nil ? "Loading…" : "All clear 🎉")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            ForEach(store.top) { task in
                TaskRow(task: task, bucket: store.planner.bucket(task, now: store.now))
            }
            let more = store.rankedCount - store.top.count
            if more > 0 {
                Text("+\(more) more today")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .animation(.snappy, value: store.top.map(\.id))
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
                        .foregroundStyle(bucket == .overdue ? .orange : .secondary)
                }
            }
            Spacer(minLength: 0)
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
            if let url = task.url { Link("Open in Notion", destination: url) }
        }
        .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
    }

    private var canStart: Bool { !task.startChanges(now: store.now).isEmpty }

    private var priorityColor: Color {
        switch task.priority {
        case .high: .red
        case .medium: .yellow
        case .low, nil: .secondary
        }
    }

    private var detail: String? {
        var parts: [String] = []
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

    /// "▶ 10:12 · 25m" while running, "10:12–10:40 · 28m" once finished.
    private var tracking: String? {
        let time = { (d: Date) in d.formatted(date: .omitted, time: .shortened) }
        switch (task.startedAt, task.finishedAt) {
        case let (start?, end?) where task.done:
            return "\(time(start))–\(time(end)) · \(duration(end.timeIntervalSince(start)))"
        case let (nil, end?) where task.done:
            return "Finished \(time(end))"
        case let (start?, _) where !task.done:
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

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if store.timeline.isEmpty {
                Text("Nothing scheduled. Add one with @10:00")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            ForEach(store.timeline) { task in
                let current = isCurrent(task)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(task.date!.start.formatted(date: .omitted, time: .shortened))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 58, alignment: .trailing)
                    TaskRow(task: task, bucket: store.planner.bucket(task, now: store.now))
                }
                .padding(.vertical, 2)
                .padding(.horizontal, 4)
                .background(current ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    /// Active between start and end; without an end, for 30 minutes.
    private func isCurrent(_ task: TodoTask) -> Bool {
        guard let d = task.date, !task.done else { return false }
        let end = d.end ?? d.start.addingTimeInterval(30 * 60)
        return d.start <= store.now && store.now < end
    }
}

struct QuickAddField: View {
    @Environment(TaskStore.self) private var store
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Add task  (@10:00  !h  *daily  ~)", text: $text)
            .textFieldStyle(.plain)
            .font(.callout)
            .padding(6)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
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
                    .help(db.lastEdited.map { "Edited \($0.formatted(.relative(presentation: .named)))" } ?? "")
                }
                Divider()
            }
            // Integration tokens can't create workspace-level pages; they go through a shared page below.
            if !usesToken {
                Button(found.isEmpty ? "Create “YATD” page in Notion" : "Create a new one instead") {
                    Task { await store.createDatabase() }
                }
            }
        } else {
            // Search failed (error shown below): don't offer Create, it could duplicate.
            Button("Search again") { Task { await store.discover() } }
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
                .disabled(token.isEmpty)
            }
        }
    }
}

extension Notification.Name {
    static let focusQuickAdd = Notification.Name("YATDFocusQuickAdd")
}
