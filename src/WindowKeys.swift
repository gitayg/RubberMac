import AppKit
import Carbon.HIToolbox

// Snap to a grid of panes, maximize and minimize from ⌘+arrows (or ⌃⌥+arrows). Handled in the keyboard
// tap rather than as hotkeys, so the ⌘←/→ that TextNavKeys makes from Home/End reaches the app instead of snapping.
final class WindowKeys: TapHandler {
    var isEnabled = false
    var keys: SnapKeys = .command
    var grid = SnapGrid.standard
    var isActive: Bool { isEnabled }

    private var swallowedKeyUps: Set<Int> = []

    func handle(_ type: CGEventType, _ event: CGEvent) -> CGEvent? {
        guard isEnabled, type == .keyDown || type == .keyUp else { return event }
        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        if type == .keyUp { return swallowedKeyUps.remove(keyCode) == nil ? event : nil }
        // RubberMAC in front means its own panel, whose search field wants ⌘←/→ and which isn't a window to snap.
        guard let command = Self.command(keyCode: keyCode, flags: event.flags.rawValue, keys: keys), Frontmost.pid != getpid() else {
            return event
        }
        swallowedKeyUps.insert(keyCode)
        // Holding the keys would otherwise fling the window across every screen.
        guard event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else { return nil }
        DispatchQueue.main.async { [grid] in WindowSnapper.snap(command, grid: grid) }
        return nil
    }

    static func command(keyCode: Int, flags: UInt64, keys: SnapKeys) -> SnapDirection? {
        let held = flags & (Modifiers.control | Modifiers.command | Modifiers.option | Modifiers.shift)
        let wanted = keys == .command ? Modifiers.command : Modifiers.control | Modifiers.option
        guard held == wanted else { return nil }
        switch keyCode {
        case kVK_LeftArrow: return .left
        case kVK_RightArrow: return .right
        case kVK_UpArrow: return .up
        case kVK_DownArrow: return .down
        default: return nil
        }
    }
}
