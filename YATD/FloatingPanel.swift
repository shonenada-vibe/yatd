import AppKit
import SwiftUI

/// A borderless panel that can float above every app and Space without stealing focus.
final class FloatingPanel: NSPanel {
    init<Content: View>(@ViewBuilder content: () -> Content) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
            // Not resizable: the content sets the size, and the top edge stays put (see setFrame).
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        [.closeButton, .miniaturizeButton, .zoomButton].forEach { standardWindowButton($0)?.isHidden = true }
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isOpaque = false
        backgroundColor = .clear
        // Liquid Glass shapes cast their own shadows; a window shadow would outline the gaps.
        if #available(macOS 26.0, *) { hasShadow = false } else { hasShadow = true }
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

        let host = NSHostingController(rootView: content())
        host.sizingOptions = [.preferredContentSize]
        contentViewController = host
        setContentSize(host.view.fittingSize)

        // Position before enabling autosave, which would otherwise save this unplaced frame.
        if !setFrameUsingName("YATDPanel") { positionTopRight() }
        setFrameAutosaveName("YATDPanel")
        keepOnScreen()
    }

    /// Pulls the panel back if a saved position is off every connected screen (e.g. a monitor was unplugged).
    func keepOnScreen() {
        let screen = NSScreen.screens.first { $0.visibleFrame.intersects(frame) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        var f = frame
        f.origin.x = min(max(f.minX, visible.minX), visible.maxX - f.width)
        f.origin.y = min(max(f.minY, visible.minY), visible.maxY - f.height)
        if f != frame { setFrame(f, display: false) }
    }

    /// AppKit keeps the bottom edge when the height changes; keep the top edge instead, so
    /// minimizing, restoring and tasks coming and going don't make the panel jump.
    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        var rect = frameRect
        if isVisible, rect.size != frame.size, rect.origin == frame.origin {
            rect.origin.y = frame.maxY - rect.height
        }
        super.setFrame(rect, display: flag)
    }

    // Needed so the quick-add field can receive typing.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func setAlwaysOnTop(_ on: Bool) {
        level = on ? .floating : .normal
    }

    private func positionTopRight() {
        guard let screen = NSScreen.main?.visibleFrame else { return }
        setFrameTopLeftPoint(NSPoint(x: screen.maxX - frame.width - 20, y: screen.maxY - 20))
    }
}
