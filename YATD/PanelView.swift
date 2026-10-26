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
            if !store.isConfigured {
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
        }
        .contentShape(Rectangle())
        .contextMenu {
            if let url = task.url { Link("Open in Notion", destination: url) }
        }
        .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
    }

    private var priorityColor: Color {
        switch task.priority {
        case .high: .red
        case .medium: .yellow
        case .low, nil: .secondary
        }
    }

    private var detail: String? {
        var parts: [String] = []
        if let d = task.date {
            if bucket == .overdue {
                parts.append("Overdue · \(d.start.formatted(.dateTime.month(.abbreviated).day()))")
            } else if d.hasTime {
                parts.append(timeRange(d))
            }
        }
        if let r = task.repeat { parts.append("↻ \(r.rawValue)") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Connect a Notion database").font(.subheadline.bold())
            Button("Create “YATD” page in Notion") {
                Task { await store.createDatabase() }
            }
            Text("or paste a database URL:").font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField("https://notion.so/…", text: $input)
                    .textFieldStyle(.roundedBorder)
                Button("Connect") { Task { await store.connect(input) } }
                    .disabled(input.isEmpty)
            }
        }
    }
}

extension Notification.Name {
    static let focusQuickAdd = Notification.Name("YATDFocusQuickAdd")
}
