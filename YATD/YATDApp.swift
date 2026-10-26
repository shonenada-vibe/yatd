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
        SettingsLink { Text("Settings…") }
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
        hotKey = HotKey { [weak self] in self?.togglePanel() }
        if UserDefaults.standard.bool(forKey: Pref.reminders) { store.requestNotificationPermission() }
        store.start()
    }

    private func applyPrefs() {
        panel.setAlwaysOnTop(UserDefaults.standard.bool(forKey: Pref.alwaysOnTop))
    }

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
