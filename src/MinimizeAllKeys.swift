import AppKit
import Carbon.HIToolbox
import Synchronization

// Windows-style Win+M (⌘M on a Mac, or the Windows key on a PC keyboard): minimize every window.
// ⌘⇧M (Win+Shift+M) brings back the windows it minimized. Remote desktops and VMs keep the keys.
final class MinimizeAllKeys: TapHandler {
    enum Command: Equatable {
        case minimizeAll, restore
    }

    var isEnabled = false
    var isActive: Bool { isEnabled }

    // Main thread only; the tap's thread reads canRestore.
    private var minimized: [SwitcherEntry] = [] {
        didSet { canRestore.store(!minimized.isEmpty, ordering: .relaxed) }
    }
    private let canRestore = Atomic<Bool>(false)

    func handle(_ type: CGEventType, _ event: CGEvent) -> CGEvent? {
        guard isEnabled, type == .keyDown || type == .keyUp else { return event }
        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let app = Frontmost.bundleID
        guard let command = Self.command(keyCode: keyCode, flags: event.flags.rawValue, app: app) else { return event }
        // With nothing to bring back, ⌘⇧M keeps its usual meaning in the app.
        if command == .restore && !canRestore.load(ordering: .relaxed) { return event }
        if type == .keyDown && event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
            DispatchQueue.main.async { command == .minimizeAll ? self.minimizeAll() : self.restore() }
        }
        return nil
    }

    static func command(keyCode: Int, flags: UInt64, app: String?) -> Command? {
        guard keyCode == kVK_ANSI_M, !AppLists.remote.contains(app ?? "") else { return nil }
        let held = flags & (Modifiers.control | Modifiers.command | Modifiers.option | Modifiers.shift)
        switch held {
        case Modifiers.command: return .minimizeAll
        case Modifiers.command | Modifiers.shift: return .restore
        default: return nil
        }
    }

    private func minimizeAll() {
        // Only what's in view: the switcher also lists windows on other Spaces and of hidden apps.
        let windows = SwitcherSource.snapshot().filter {
            !$0.isMinimized && $0.isOnCurrentSpace && NSRunningApplication(processIdentifier: $0.pid)?.isHidden != true
        }
        guard !windows.isEmpty else { return }
        minimized = windows
        log("minimize all: \(windows.count) windows")
        DispatchQueue.global(qos: .userInitiated).async {
            windows.forEach { AX.setMinimized($0.window, true) }
        }
    }

    // Back to front, so the window that was in front ends up on top and focused again.
    private func restore() {
        let windows = minimized
        minimized = []
        log("restore: \(windows.count) windows")
        DispatchQueue.global(qos: .userInitiated).async {
            windows.reversed().forEach { AX.setMinimized($0.window, false) }
            if let front = windows.first { AX.focus(front.window, pid: front.pid) }
        }
    }
}
