import AppKit

// Start's window. A non-activating panel, so the app in front stays in front (and keeps its menu bar) while Start takes
// the typing; above the Dock and the menu bar, on every desktop and over full-screen apps; below menus, so its own
// right-click menu shows on top of it.
final class StartMenuPanel: NSPanel {
    static let level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue - 1)

    init(content: NSView) {
        super.init(contentRect: content.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = Self.level
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = false
        // Said outright: left unset, clicks on a see-through window pass through its clear parts to what's behind.
        ignoresMouseEvents = false
        contentView = content
    }

    // Borderless panels can't become key by default, and Start has to take typing.
    override var canBecomeKey: Bool { true }
}
