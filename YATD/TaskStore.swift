import AppKit
import Foundation
import Observation
import UserNotifications
import YATDCore

@MainActor
@Observable
final class TaskStore {
    private(set) var open: [TodoTask] = []
    private(set) var doneToday: [TodoTask] = []
    private(set) var lastSync: Date?
    private(set) var isSyncing = false
    var error: String?
    /// Re-read every minute so "now" buckets and the timeline move along.
    private(set) var now = Date.now
    private(set) var config: SourceConfig?
    /// YATD databases found in the workspace, for the setup screen. `nil` until searched.
    private(set) var discovered: [DiscoveredDatabase]?
    private(set) var isDiscovering = false

    /// Edits that haven't reached Notion yet; refreshes re-apply them so the UI doesn't flicker back.
    private var pending: [String: [TaskChange]] = [:]
    /// Whether the connected database has been checked for the Started/Finished properties.
    private var schemaChecked = false
    private var loop: Task<Void, Never>?

    var planner: Planner {
        Planner(dayStartHour: UserDefaults.standard.integer(forKey: Pref.dayStartHour))
    }

    var top: [TodoTask] { planner.top(open, now: now) }
    var rankedCount: Int { planner.ranked(open, now: now).count }
    var timeline: [TodoTask] { planner.timeline(open + doneToday, now: now) }
    var isConfigured: Bool { config != nil }

    init() {
        config = Pref.sourceConfig
        loadCache()
    }

    // MARK: Source

    /// Whether the app can talk to Notion yet (always true for ntn; a saved token otherwise).
    private(set) var hasCredentials = Pref.connectionMode == .ntn || Keychain.token != nil
    private(set) var connection = Pref.connectionMode

    private func transport() throws -> any NotionTransport {
        switch Pref.connectionMode {
        case .ntn:
            guard let cli = NtnCLI.locate(preferred: UserDefaults.standard.string(forKey: Pref.ntnPath)) else {
                throw NotionError.cliNotFound
            }
            return cli
        case .token:
            guard let token = Keychain.token else { throw NotionError.notSignedIn }
            return NotionHTTP(token: token)
        }
    }

    private func source() throws -> any TaskSource {
        guard let config else { throw NotionError.notConfigured }
        return NotionSource(dataSourceID: config.dataSourceID, transport: try transport())
    }

    func setConnection(_ mode: Connection, token: String?) async {
        await perform {
            Pref.connectionMode = mode
            self.connection = Pref.connectionMode
            if mode == .token { try Keychain.setToken(token?.trimmingCharacters(in: .whitespacesAndNewlines)) }
            self.hasCredentials = mode == .ntn || Keychain.token != nil
            self.schemaChecked = false
            self.error = nil
        }
        if config == nil { await discover() } else { await refresh() }
    }

    func connect(_ input: String) async {
        await perform {
            let config = try await NotionSource.resolve(input, transport: try self.transport())
            self.setConfig(config)
        }
        await refresh()
    }

    func connect(_ found: DiscoveredDatabase) async {
        setConfig(found.config)
        await refresh()
    }

    /// Looks for an existing YATD database so a second Mac reuses it instead of creating another.
    func discover() async {
        isDiscovering = true
        defer { isDiscovering = false }
        await perform {
            self.discovered = try await NotionSource.discover(transport: try self.transport())
        }
    }

    func createDatabase() async {
        await perform {
            let config = try await NotionSource.bootstrap(transport: try self.transport())
            self.setConfig(config)
        }
        await refresh()
    }

    private func setConfig(_ config: SourceConfig) {
        Pref.sourceConfig = config
        self.config = config
        schemaChecked = false
        open = []
        doneToday = []
        saveCache()
    }

    // MARK: Sync

    func start() {
        loop?.cancel()
        loop = Task { [weak self] in
            var lastPoll = Date.distantPast
            while !Task.isCancelled {
                guard let self else { return }
                self.now = .now
                let interval = TimeInterval(max(15, UserDefaults.standard.integer(forKey: Pref.pollSeconds)))
                if Date.now.timeIntervalSince(lastPoll) >= interval {
                    lastPoll = .now
                    await self.refresh()
                }
                try? await Task.sleep(for: .seconds(15))
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    func refresh() async {
        guard config != nil, hasCredentials, !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        now = .now
        await perform {
            let source = try self.source()
            let planner = self.planner
            if !self.schemaChecked {
                try await source.ensureSchema()
                self.schemaChecked = true
            }
            async let openTasks = source.fetchOpen()
            async let doneTasks = source.fetchDone(on: planner.today(.now))
            var fetched = try await openTasks
            let done = try await doneTasks

            // Daily schedule: recurring tasks left undone on a past day move to today.
            for (task, newDate) in planner.rollovers(fetched, now: .now) {
                try await source.update(task.id, [.date(newDate)])
                if let i = fetched.firstIndex(where: { $0.id == task.id }) { fetched[i].date = newDate }
            }

            // Two Macs completing the same recurring task at once can each create the next copy.
            for dup in planner.duplicates(fetched) {
                try await source.trash(dup.id)
                fetched.removeAll { $0.id == dup.id }
            }

            self.apply(open: fetched, done: done)
            self.lastSync = .now
            self.error = nil
        }
        saveCache()
        scheduleReminders()
    }

    private func apply(open fetched: [TodoTask], done: [TodoTask]) {
        var all = fetched + done
        for (id, changes) in pending {
            if let i = all.firstIndex(where: { $0.id == id }) { all[i] = all[i].applying(changes) }
        }
        open = all.filter { !$0.done }
        doneToday = all.filter(\.done)
    }

    // MARK: Edits

    func start(_ task: TodoTask) {
        edit(task, task.startChanges(now: .now))
    }

    func complete(_ task: TodoTask) {
        let next = planner.nextInstance(after: task, now: .now)
        edit(task, task.completeChanges(now: .now)) { source in
            guard let next else { return }
            // Another Mac may have completed this task and created the next copy already.
            let existing = try await source.openTasks(titled: next.title)
            if !self.planner.alreadyScheduled(next, in: existing) {
                self.open.append(try await source.create(next))
            }
        }
    }

    func reopen(_ task: TodoTask) {
        edit(task, task.reopenChanges())
    }

    /// Applies `changes` locally at once, then writes them to Notion.
    private func edit(_ task: TodoTask, _ changes: [TaskChange],
                      then followUp: (@MainActor (any TaskSource) async throws -> Void)? = nil) {
        guard !changes.isEmpty, !task.id.hasPrefix("local-") else { return }
        let all = open + doneToday
        guard let current = all.first(where: { $0.id == task.id }) else { return }
        let updated = current.applying(changes)
        open = open.filter { $0.id != task.id } + (updated.done ? [] : [updated])
        doneToday = doneToday.filter { $0.id != task.id } + (updated.done ? [updated] : [])
        pending[task.id, default: []] += changes

        Task {
            await perform {
                let source = try self.source()
                try await source.update(task.id, changes)
                try await followUp?(source)
            }
            pending[task.id] = nil
            if error != nil { await refresh() }
            saveCache()
        }
    }

    func quickAdd(_ text: String) {
        guard let draft = QuickAdd.parse(text, today: planner.today(.now)) else { return }
        // Shown right away with a temporary ID; replaced when Notion answers.
        var placeholder = draft
        placeholder.id = "local-\(UUID().uuidString)"
        placeholder.createdTime = .now
        open.append(placeholder)
        Task {
            await perform {
                let created = try await self.source().create(draft)
                if let i = self.open.firstIndex(where: { $0.id == placeholder.id }) { self.open[i] = created }
            }
            if error != nil { open.removeAll { $0.id == placeholder.id } }
            saveCache()
            scheduleReminders()
        }
    }

    private func perform(_ work: @MainActor () async throws -> Void) async {
        do { try await work() } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: Reminders

    func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func scheduleReminders() {
        let center = UNUserNotificationCenter.current()
        center.removeAllPendingNotificationRequests()
        guard UserDefaults.standard.bool(forKey: Pref.reminders) else { return }
        for task in planner.timeline(open, now: now) {
            guard let start = task.date?.start, start > .now else { continue }
            let content = UNMutableNotificationContent()
            content.title = task.title
            content.body = "Starts now"
            content.sound = .default
            let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: start)
            let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
            center.add(UNNotificationRequest(identifier: task.id, content: content, trigger: trigger))
        }
    }

    // MARK: Cache

    private struct Cache: Codable {
        var open: [TodoTask]
        var doneToday: [TodoTask]
        var lastSync: Date?
        var dataSourceID: String?
    }

    private var cacheURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("YATD", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("cache.json")
    }

    private func loadCache() {
        guard let data = try? Data(contentsOf: cacheURL),
              let cache = try? JSONDecoder().decode(Cache.self, from: data),
              cache.dataSourceID == config?.dataSourceID
        else { return }
        open = cache.open.filter { !$0.id.hasPrefix("local-") }
        doneToday = cache.doneToday
        lastSync = cache.lastSync
    }

    private func saveCache() {
        let cache = Cache(open: open, doneToday: doneToday, lastSync: lastSync, dataSourceID: config?.dataSourceID)
        if let data = try? JSONEncoder().encode(cache) { try? data.write(to: cacheURL, options: .atomic) }
    }
}
