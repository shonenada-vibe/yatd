import AppKit
import Foundation
import Observation
import UserNotifications
import YATDCore

@MainActor
@Observable
final class TaskStore {
    /// Tasks from every project synced so far; views filter to the active projects.
    private var allOpen: [TodoTask] = []
    private var allDone: [TodoTask] = []
    private(set) var lastSync: Date?
    private(set) var isSyncing = false
    var error: String?
    /// Re-read every 15s so "now" buckets, the timeline and the schedule move along.
    private(set) var now = Date.now
    /// YATD databases found in the workspace, for setup and "Add existing". `nil` until searched.
    private(set) var discovered: [DiscoveredDatabase]?
    private(set) var isDiscovering = false

    private(set) var projects: [Project] = Pref.projects
    private(set) var rules: [ScheduleRule] = Pref.rules
    private(set) var selection: ProjectSelection = Pref.selection

    /// Edits that haven't reached Notion yet; refreshes re-apply them so the UI doesn't flicker back.
    private var pending: [String: [TaskChange]] = [:]
    /// Projects whose database has been checked for new properties and had its name refreshed.
    private var checkedProjects: Set<String> = []
    private var loop: Task<Void, Never>?
    /// The code block holding shared settings on the YATD page, once found.
    private var settingsBlockID: String?
    private var pushSettings: Task<Void, Never>?
    /// One settings sync at a time: two at once could both create the settings block.
    private var isSyncingSettings = false
    /// Last shared-settings sync result, for Settings ("Synced via Notion" or the error).
    private(set) var sharedSettingsStatus: String?

    var planner: Planner {
        Planner(dayStartHour: UserDefaults.standard.integer(forKey: Pref.dayStartHour))
    }

    // MARK: Projects

    var activeProjectIDs: [String] {
        ProjectScheduler().activeProjectIDs(projects, rules: rules, selection: selection, now: now)
    }

    var activeProjects: [Project] {
        let ids = Set(activeProjectIDs)
        return projects.filter { ids.contains($0.id) }
    }

    /// The schedule rule in effect, for showing why these projects are active.
    var currentRule: ScheduleRule? {
        guard selection == .auto else { return nil }
        return ProjectScheduler().matchingRule(rules, projects: projects, now: now)
    }

    func project(_ id: String?) -> Project? { projects.first { $0.id == id } }

    var open: [TodoTask] { allOpen.filter(isActive) }
    var doneToday: [TodoTask] { allDone.filter(isActive) }

    private func isActive(_ task: TodoTask) -> Bool {
        task.projectID.map(activeProjectIDs.contains) ?? true
    }

    var top: [TodoTask] { planner.top(open, now: now) }
    var rankedCount: Int { planner.ranked(open, now: now).count }
    var timeline: [TodoTask] { planner.timeline(open + doneToday, now: now) }
    var isConfigured: Bool { !projects.isEmpty }

    init() {
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

    private func source(_ projectID: String?) throws -> any TaskSource {
        guard let id = projectID ?? activeProjectIDs.first ?? projects.first?.id else { throw NotionError.notConfigured }
        return NotionSource(dataSourceID: id, transport: try transport())
    }

    func setConnection(_ mode: Connection, token: String?) async {
        await perform {
            Pref.connectionMode = mode
            self.connection = Pref.connectionMode
            if mode == .token { try Keychain.setToken(token?.trimmingCharacters(in: .whitespacesAndNewlines)) }
            self.hasCredentials = mode == .ntn || Keychain.token != nil
            self.checkedProjects = []
            self.error = nil
        }
        if projects.isEmpty { await discover() } else { await refresh() }
    }

    /// Adds a database by URL/ID (or creates one inside a pasted page URL) as a project.
    func connect(_ input: String) async {
        await perform {
            let config = try await NotionSource.resolve(input, transport: try self.transport())
            self.addProject(Project(config, name: "Tasks"))
        }
        await refresh()
    }

    func connect(_ found: DiscoveredDatabase) async {
        addProject(Project(found.config, name: found.title))
        await refresh()
    }

    /// Looks for existing YATD databases so a second Mac reuses them instead of creating more.
    func discover() async {
        isDiscovering = true
        defer { isDiscovering = false }
        await perform {
            self.discovered = try await NotionSource.discover(transport: try self.transport())
        }
    }

    /// Databases found in the workspace that aren't projects yet.
    var addableDatabases: [DiscoveredDatabase] {
        let known = Set(projects.map(\.id))
        return (discovered ?? []).filter { !known.contains($0.id) }
    }

    func createDatabase() async {
        await perform {
            let config = try await NotionSource.bootstrap(transport: try self.transport())
            // bootstrap's pageURL is the new YATD page, which will hold project pages.
            if let root = config.pageURL.flatMap({ NotionCoding.extractID($0.absoluteString) }) {
                UserDefaults.standard.set(root, forKey: Pref.rootPageID)
            }
            self.addProject(Project(config, name: "Tasks"))
        }
        await refresh()
    }

    /// Creates a project page (with its own tasks database) inside the YATD page.
    func createProject(named rawName: String) async {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        await perform {
            let transport = try self.transport()
            let parent = try await self.rootPageID(transport)
            let project = try await NotionSource.createProject(named: name, parentPageID: parent, transport: transport)
            self.addProject(project)
            // Show the new (empty) project right away when picking projects by hand.
            if case .manual(let ids) = self.selection { self.setSelection(.manual(ids + [project.id])) }
        }
        await refresh()
    }

    /// The YATD page that holds project pages. Remembered once known; otherwise derived from the
    /// first project: the original Tasks database sits directly in the YATD page, while a created
    /// project's database sits in a project page (named like it) one level further down.
    private func rootPageID(_ transport: any NotionTransport) async throws -> String {
        if let id = UserDefaults.standard.string(forKey: Pref.rootPageID) { return id }
        guard let first = projects.first else { throw NotionError.notConfigured }
        let meta = try await NotionSource(dataSourceID: first.id, transport: transport).metadata()
        guard var root = meta.parentPageID else {
            throw NotionError.unexpectedResponse("The first project's database isn't inside a page.")
        }
        let page = try await NotionSource.pageInfo(root, transport: transport)
        if page.title == meta.title, let grandparent = page.parentPageID { root = grandparent }
        UserDefaults.standard.set(root, forKey: Pref.rootPageID)
        return root
    }

    private func addProject(_ project: Project) {
        guard !projects.contains(where: { $0.id == project.id }) else { return }
        projects.append(project)
        Pref.projects = projects
        sharedSettingsChanged()
    }

    /// Stops showing a project in YATD. Its page and tasks stay in Notion.
    func removeProject(_ id: String) {
        projects.removeAll { $0.id == id }
        Pref.projects = projects
        allOpen.removeAll { $0.projectID == id }
        allDone.removeAll { $0.projectID == id }
        rules = rules.map { var r = $0; r.projectIDs.removeAll { $0 == id }; return r }
        Pref.rules = rules
        pushSettings?.cancel()
        if case .manual(let ids) = selection { setSelection(.manual(ids.filter { $0 != id })) }
        saveCache()
        sharedSettingsChanged()
    }

    func moveProjects(from source: IndexSet, to destination: Int) {
        projects.move(fromOffsets: source, toOffset: destination)
        Pref.projects = projects
        sharedSettingsChanged()
    }

    func setSelection(_ new: ProjectSelection) {
        selection = new
        Pref.selection = new
        Task { await refresh() }
    }

    /// Shows or hides one project by hand, starting from whatever is active now.
    func toggleProject(_ id: String) {
        var ids = activeProjectIDs
        if case .manual(let picked) = selection { ids = picked }
        if ids.contains(id) { ids.removeAll { $0 == id } } else { ids.append(id) }
        setSelection(.manual(ids))
    }

    func setRules(_ new: [ScheduleRule]) {
        rules = new
        Pref.rules = new
        sharedSettingsChanged()
    }

    // MARK: Shared settings

    /// Projects, rules and the day start as this Mac has them now.
    private var localShared: SharedSettings {
        SharedSettings(projects: projects, rules: rules,
                       dayStartHour: UserDefaults.standard.integer(forKey: Pref.dayStartHour))
    }

    /// Writes local changes to Notion after a short pause, so dragging a time picker
    /// doesn't write on every tick.
    func sharedSettingsChanged() {
        pushSettings?.cancel()
        pushSettings = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let transport = try? self.transport() else { return }
            await self.syncSharedSettings(transport)
        }
    }

    /// Reconciles this Mac with the settings block on the YATD page:
    /// - none yet: write ours;
    /// - first sync from this Mac: merge ours into the shared copy;
    /// - only Notion changed: take it; only we changed: write ours;
    /// - both changed: ours wins (it's the newer, deliberate edit).
    private func syncSharedSettings(_ transport: any NotionTransport) async {
        // A skipped sync isn't lost: the next one still sees local != last and writes it.
        guard isConfigured, !isSyncingSettings else { return }
        isSyncingSettings = true
        defer { isSyncingSettings = false }
        do {
            let doc = NotionSettingsDocument(rootPageID: try await rootPageID(transport), transport: transport)
            let loaded = try await doc.load()
            settingsBlockID = loaded.codeBlockID ?? settingsBlockID
            let local = localShared
            let last = Pref.lastShared

            var result = local
            if let remote = loaded.settings {
                if last == nil {
                    result = remote.merged(withLocal: local)
                } else if remote != last, local == last {
                    result = remote
                }
                if result != local { applyShared(result) }
            }
            if result != loaded.settings {
                settingsBlockID = try await doc.save(result, codeBlockID: loaded.codeBlockID)
            }
            Pref.lastShared = result
            sharedSettingsStatus = "Shared with your other Macs via the YATD page in Notion."
        } catch {
            sharedSettingsStatus = "Couldn't sync settings to Notion: \(error.localizedDescription)"
        }
    }

    private func applyShared(_ shared: SharedSettings) {
        let kept = Set(shared.projects.map(\.id))
        projects = shared.projects
        Pref.projects = projects
        rules = shared.rules
        Pref.rules = rules
        if let hour = shared.dayStartHour { UserDefaults.standard.set(hour, forKey: Pref.dayStartHour) }
        allOpen.removeAll { $0.projectID.map { !kept.contains($0) } ?? false }
        allDone.removeAll { $0.projectID.map { !kept.contains($0) } ?? false }
    }

    // MARK: Sync

    func start() {
        loop?.cancel()
        loop = Task { [weak self] in
            var lastPoll = Date.distantPast
            var lastActive: [String] = []
            while !Task.isCancelled {
                guard let self else { return }
                self.now = .now
                let interval = TimeInterval(max(15, UserDefaults.standard.integer(forKey: Pref.pollSeconds)))
                // Sync on the poll interval, and straight away when the schedule switches projects.
                if Date.now.timeIntervalSince(lastPoll) >= interval || self.activeProjectIDs != lastActive {
                    lastPoll = .now
                    lastActive = self.activeProjectIDs
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
        guard isConfigured, hasCredentials, !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        now = .now
        // Another Mac may have added projects or changed the schedule.
        if let transport = try? transport() { await syncSharedSettings(transport) }
        let ids = activeProjectIDs
        await perform {
            let transport = try self.transport()
            let planner = self.planner
            var fetchedOpen: [TodoTask] = []
            var fetchedDone: [TodoTask] = []
            for id in ids {
                let source = NotionSource(dataSourceID: id, transport: transport)
                if !self.checkedProjects.contains(id) {
                    try await source.ensureSchema()
                    let meta = try await source.metadata()
                    self.rename(id, to: meta.title)
                    self.checkedProjects.insert(id)
                }
                async let openTasks = source.fetchOpen()
                async let doneTasks = source.fetchDone(on: planner.today(.now))
                var open = try await openTasks
                fetchedDone += try await doneTasks

                // Daily schedule: recurring tasks left undone on a past day move to today.
                for (task, newDate) in planner.rollovers(open, now: .now) {
                    let changes = planner.rolloverChanges(task, newDate: newDate)
                    try await source.update(task.id, changes)
                    if let i = open.firstIndex(where: { $0.id == task.id }) { open[i] = open[i].applying(changes) }
                }
                // Two Macs completing the same recurring task at once can each create the next copy.
                for dup in planner.duplicates(open) {
                    try await source.trash(dup.id)
                    open.removeAll { $0.id == dup.id }
                }
                fetchedOpen += open
            }
            self.apply(open: fetchedOpen, done: fetchedDone, projects: Set(ids))
            self.lastSync = .now
            self.error = nil
        }
        saveCache()
        scheduleReminders()
    }

    private func rename(_ id: String, to title: String) {
        guard !title.isEmpty, let i = projects.firstIndex(where: { $0.id == id }), projects[i].name != title else { return }
        projects[i].name = title
        Pref.projects = projects
    }

    /// Replaces the synced projects' tasks, keeping cached tasks of projects not synced this time.
    private func apply(open fetched: [TodoTask], done: [TodoTask], projects synced: Set<String>) {
        let keep = { (t: TodoTask) in t.projectID.map { !synced.contains($0) } ?? false }
        var all = allOpen.filter(keep) + allDone.filter(keep) + fetched + done
        for (id, changes) in pending {
            if let i = all.firstIndex(where: { $0.id == id }) { all[i] = all[i].applying(changes) }
        }
        allOpen = all.filter { !$0.done }
        allDone = all.filter(\.done)
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
                self.allOpen.append(try await source.create(next))
            }
        }
    }

    func reopen(_ task: TodoTask) {
        edit(task, task.reopenChanges())
    }

    /// Sets or clears when you plan to start the task.
    func setPlannedStart(_ task: TodoTask, _ date: Date?) {
        guard date != task.plannedStart else { return }
        edit(task, [.plannedStart(date)])
        scheduleReminders()
    }

    /// Applies `changes` locally at once, then writes them to the task's project in Notion.
    private func edit(_ task: TodoTask, _ changes: [TaskChange],
                      then followUp: (@MainActor (any TaskSource) async throws -> Void)? = nil) {
        guard !changes.isEmpty, !task.id.hasPrefix("local-") else { return }
        guard let current = (allOpen + allDone).first(where: { $0.id == task.id }) else { return }
        let updated = current.applying(changes)
        allOpen = allOpen.filter { $0.id != task.id } + (updated.done ? [] : [updated])
        allDone = allDone.filter { $0.id != task.id } + (updated.done ? [updated] : [])
        pending[task.id, default: []] += changes

        Task {
            await perform {
                let source = try self.source(task.projectID)
                try await source.update(task.id, changes)
                try await followUp?(source)
            }
            pending[task.id] = nil
            if error != nil { await refresh() }
            saveCache()
        }
    }

    /// Adds to the `#project` named in the text, or the first active project.
    func quickAdd(_ text: String) {
        guard var draft = QuickAdd.parse(text, today: planner.today(.now), projects: projects) else { return }
        draft.projectID = draft.projectID ?? activeProjectIDs.first
        // Shown right away with a temporary ID; replaced when Notion answers.
        var placeholder = draft
        placeholder.id = "local-\(UUID().uuidString)"
        placeholder.createdTime = .now
        allOpen.append(placeholder)
        Task {
            await perform {
                let created = try await self.source(draft.projectID).create(draft)
                if let i = self.allOpen.firstIndex(where: { $0.id == placeholder.id }) { self.allOpen[i] = created }
            }
            if error != nil { allOpen.removeAll { $0.id == placeholder.id } }
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
            guard let start = planner.scheduledStart(task, now: now), start > .now else { continue }
            let content = UNMutableNotificationContent()
            content.title = task.title
            let when = task.date?.hasTime == true ? "Starts now" : "Planned to start now"
            content.body = project(task.projectID).map { "\(when) · \($0.name)" } ?? when
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
    }

    private var cacheURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("YATD", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("cache.json")
    }

    private func loadCache() {
        guard let data = try? Data(contentsOf: cacheURL),
              let cache = try? JSONDecoder().decode(Cache.self, from: data)
        else { return }
        // Tasks cached before projects existed have no project; they belong to the first one.
        let known = Set(projects.map(\.id))
        let fix = { (t: TodoTask) -> TodoTask? in
            var t = t
            if t.projectID == nil { t.projectID = self.projects.first?.id }
            guard let p = t.projectID, known.contains(p), !t.id.hasPrefix("local-") else { return nil }
            return t
        }
        allOpen = cache.open.compactMap(fix)
        allDone = cache.doneToday.compactMap(fix)
        lastSync = cache.lastSync
    }

    private func saveCache() {
        let cache = Cache(open: allOpen, doneToday: allDone, lastSync: lastSync)
        if let data = try? JSONEncoder().encode(cache) { try? data.write(to: cacheURL, options: .atomic) }
    }
}
