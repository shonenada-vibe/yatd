import Carbon.HIToolbox
import Foundation

/// A system-wide shortcut via Carbon's RegisterEventHotKey (no Accessibility permission needed).
@MainActor
final class HotKey {
    nonisolated(unsafe) private var ref: EventHotKeyRef?
    nonisolated(unsafe) private var handler: EventHandlerRef?
    private let action: @MainActor () -> Void

    /// Defaults to ⌥⌘Y.
    init(keyCode: Int = kVK_ANSI_Y, modifiers: Int = optionKey | cmdKey, action: @escaping @MainActor () -> Void) {
        self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let me = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            let hotKey = Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated { hotKey.action() }
            return noErr
        }, 1, &spec, me, &handler)
        let id = EventHotKeyID(signature: OSType(0x5941_5444), id: 1) // "YATD"
        RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), id, GetApplicationEventTarget(), 0, &ref)
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        if let handler { RemoveEventHandler(handler) }
    }
}
