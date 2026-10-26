import AppKit
import SwiftUI
import YATDCore

@main
struct YATDApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("YATD", systemImage: "checklist") {
            MenuContent(panel: appDelegate)
                .environment(appDelegate.store)
        }
        Settings {
            SettingsView()
                .environment(appDelegate.store)
        }
    }
}

struct MenuContent: View {
    @Environment(TaskStore.self) private var store
    @Environment(\.openSettings) private var openSettings
    let panel: AppDelegate

    var body: some View {
        ForEach(store.top) { task in
            Button("○ \(task.title)") { store.complete(task) }
        }
        if !store.top.isEmpty { Divider() }
        Button("Show/Hide Panel") { panel.togglePanel() }
            .keyboardShortcut("y", modifiers: [.option, .command])
        Button("Add Task…") { panel.showPanel(focusAdd: true) }
        Button("Refresh") { Task { await store.refresh() } }
            .keyboardShortcut("r")
        if store.projects.count == 1, let url = store.projects[0].pageURL {
            Link("Open in Notion", destination: url)
        } else if store.projects.count > 1 {
            Menu("Open in Notion") {
                ForEach(store.projects) { project in
                    if let url = project.pageURL { Link(project.name, destination: url) }
                }
            }
        }
        Divider()
        // SettingsLink doesn't activate YATD, so Settings would open behind the current app.
        Button("Settings…") {
            NSApp.activate()
            openSettings()
        }
        .keyboardShortcut(",")
        Button("Quit YATD") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store: TaskStore
    private var panel: FloatingPanel!
    private var hotKey: HotKey?
    private var defaultsObserver: NSObjectProtocol?
    private var windowObservers: [NSObjectProtocol] = []

    override init() {
        Pref.registerDefaults()
        store = TaskStore()
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        panel = FloatingPanel { PanelView().environment(self.store) }
        applyPrefs()
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyPrefs() }
        }
        if UserDefaults.standard.bool(forKey: Pref.showPanel) { panel.orderFrontRegardless() }
        // However Settings is opened (menu, panel, ⌘,), lift it above the floating panel.
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification] {
            windowObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { note in
                let window = note.object as? NSWindow
                MainActor.assumeIsolated { Self.raiseIfSettings(window) }
            })
        }
        // Once you switch to another app, Settings goes back to being a normal window
        // instead of floating over everything.
        windowObservers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                NSApp.windows.filter(Self.isSettings).forEach { $0.level = .normal }
            }
        })
        hotKey = HotKey { [weak self] in self?.togglePanel() }
        if UserDefaults.standard.bool(forKey: Pref.reminders) { store.requestNotificationPermission() }
        store.start()
    }

    private func applyPrefs() {
        panel.setAlwaysOnTop(UserDefaults.standard.bool(forKey: Pref.alwaysOnTop))
        applyDockPolicy()
    }

    /// Dock icon on or off at runtime. Info.plist keeps LSUIElement so launch never flashes an
    /// icon that the setting then removes.
    private func applyDockPolicy() {
        let policy: NSApplication.ActivationPolicy = UserDefaults.standard.bool(forKey: Pref.showInDock) ? .regular : .accessory
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
        // Leaving the Dock deactivates the app; keep an open Settings window in view.
        if policy == .accessory, let settings = NSApp.windows.first(where: Self.isSettings), settings.isVisible {
            NSApp.activate()
            Self.raiseIfSettings(settings)
        }
    }

    private static func isSettings(_ window: NSWindow) -> Bool {
        window.identifier?.rawValue.contains("Settings") == true
    }

    /// Puts the Settings window in front of everything, including the always-on-top panel,
    /// while YATD is the active app.
    private static func raiseIfSettings(_ window: NSWindow?) {
        guard let window, isSettings(window) else { return }
        window.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        window.collectionBehavior.insert(.moveToActiveSpace)
        window.orderFrontRegardless()
    }

    // MARK: Dock

    /// Clicking the Dock icon brings the panel back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPanel(focusAdd: false)
        return true
    }

    /// Right-click menu on the Dock icon: today's top tasks and the panel actions.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        for task in store.top {
            let item = NSMenuItem(title: "○ \(task.title)", action: #selector(completeFromDock(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = task.id
            menu.addItem(item)
        }
        if !store.top.isEmpty { menu.addItem(.separator()) }
        let toggle = NSMenuItem(title: panel.isVisible ? "Hide Panel" : "Show Panel", action: #selector(togglePanelFromDock), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)
        let add = NSMenuItem(title: "Add Task…", action: #selector(addTaskFromDock), keyEquivalent: "")
        add.target = self
        menu.addItem(add)
        return menu
    }

    @objc private func completeFromDock(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let task = store.top.first(where: { $0.id == id }) else { return }
        store.complete(task)
    }

    @objc private func togglePanelFromDock() { togglePanel() }

    @objc private func addTaskFromDock() { showPanel(focusAdd: true) }

    func togglePanel() {
        if panel.isVisible { hidePanel() } else { showPanel(focusAdd: false) }
    }

    func showPanel(focusAdd: Bool) {
        panel.orderFrontRegardless()
        UserDefaults.standard.set(true, forKey: Pref.showPanel)
        if focusAdd {
            panel.makeKey()
            NotificationCenter.default.post(name: .focusQuickAdd, object: nil)
        }
    }

    func hidePanel() {
        panel.orderOut(nil)
        UserDefaults.standard.set(false, forKey: Pref.showPanel)
    }
}
