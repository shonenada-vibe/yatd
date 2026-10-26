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

    /// IDs whose done-state change hasn't reached Notion yet; refreshes must not undo them.
    private var pending: [String: Bool] = [:]
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

    private func cli() throws -> NtnCLI {
        guard let cli = NtnCLI.locate(preferred: UserDefaults.standard.string(forKey: Pref.ntnPath)) else {
            throw NotionError.cliNotFound
        }
        return cli
    }

    private func source() throws -> any TaskSource {
        guard let config else { throw NotionError.notConfigured }
        return NtnCLISource(dataSourceID: config.dataSourceID, cli: try cli())
    }

    func connect(_ input: String) async {
        await perform {
            let config = try await NtnCLISource.resolve(input, cli: try self.cli())
            self.setConfig(config)
        }
        await refresh()
    }

    func createDatabase() async {
        await perform {
            let config = try await NtnCLISource.bootstrap(cli: try self.cli())
            self.setConfig(config)
        }
        await refresh()
    }

    private func setConfig(_ config: SourceConfig) {
        Pref.sourceConfig = config
        self.config = config
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
        guard config != nil, !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        now = .now
        await perform {
            let source = try self.source()
            let planner = self.planner
            async let openTasks = source.fetchOpen()
            async let doneTasks = source.fetchDone(on: planner.today(.now))
            var fetched = try await openTasks
            let done = try await doneTasks

            // Daily schedule: recurring tasks left undone on a past day move to today.
            for (task, newDate) in planner.rollovers(fetched, now: .now) {
                try await source.setDate(task.id, newDate)
                if let i = fetched.firstIndex(where: { $0.id == task.id }) { fetched[i].date = newDate }
            }

            self.apply(open: fetched, done: done)
            self.lastSync = .now
            self.error = nil
        }
        saveCache()
        scheduleReminders()
    }

    private func apply(open fetched: [TodoTask], done: [TodoTask]) {
        var open = fetched, done = done
        for (id, isDone) in pending {
            if isDone, let i = open.firstIndex(where: { $0.id == id }) {
                var t = open.remove(at: i); t.done = true; done.append(t)
            } else if !isDone, let i = done.firstIndex(where: { $0.id == id }) {
                var t = done.remove(at: i); t.done = false; open.append(t)
            }
        }
        self.open = open
        self.doneToday = done
    }

    // MARK: Edits

    func complete(_ task: TodoTask) {
        guard !task.id.hasPrefix("local-"), let i = open.firstIndex(where: { $0.id == task.id }) else { return }
        var t = open.remove(at: i)
        t.done = true
        doneToday.append(t)
        pending[t.id] = true
        let next = planner.nextInstance(after: t, now: .now)

        Task {
            await perform {
                let source = try self.source()
                try await source.setDone(t.id, true)
                if let next { self.open.append(try await source.create(next)) }
            }
            pending[t.id] = nil
            if error != nil { await refresh() }
            saveCache()
        }
    }

    func reopen(_ task: TodoTask) {
        guard let i = doneToday.firstIndex(where: { $0.id == task.id }) else { return }
        var t = doneToday.remove(at: i)
        t.done = false
        open.append(t)
        pending[t.id] = false
        Task {
            await perform { try await self.source().setDone(t.id, false) }
            pending[t.id] = nil
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
