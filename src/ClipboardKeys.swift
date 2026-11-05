import AppKit
import Carbon.HIToolbox

// PC-style Ctrl-C / Ctrl-X / Ctrl-V / Ctrl-Z, sent on as Command-C/X/V/Z. Left alone in terminals
// and editors with a terminal, where Ctrl-C and Ctrl-Z must still interrupt and suspend, and in
// remote-desktop and VM apps, which pass Ctrl through to Windows themselves.
final class ClipboardKeys: TapHandler {
    var isEnabled = false
    var isActive: Bool { isEnabled }

    static let passThrough = AppLists.terminals.union(AppLists.editorsWithTerminal).union(AppLists.remote)

    private static let keys: Set<Int> = [kVK_ANSI_C, kVK_ANSI_X, kVK_ANSI_V, kVK_ANSI_Z]

    func handle(_ type: CGEventType, _ event: CGEvent) -> CGEvent? {
        guard isEnabled, type == .keyDown || type == .keyUp else { return event }
        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let app = Frontmost.bundleID
        if let flags = Self.rewrite(flags: event.flags.rawValue, keyCode: keyCode, app: app) {
            event.flags = CGEventFlags(rawValue: flags)
        }
        return event
    }

    // New flags for the event, or nil to leave it alone.
    static func rewrite(flags: UInt64, keyCode: Int, app: String?) -> UInt64? {
        let others = Modifiers.command | Modifiers.option
        guard flags & Modifiers.control != 0, flags & others == 0, keys.contains(keyCode),
              !passThrough.contains(app ?? "") else { return nil }
        return Modifiers.replace(Modifiers.control, with: Modifiers.command, in: flags)
    }
}
