import AppKit
import Carbon.HIToolbox

// PC text navigation: Ctrl-←/→ jump a word (⌥←/→ on a Mac); Home/End go to the start/end of the
// line (⌘←/→). Shift still extends the selection. Remote-desktop and VM apps get the PC keys
// untouched, and terminals keep Home/End for scrolling.
final class TextNavKeys: TapHandler {
    enum Rewrite: Equatable {
        case flags(UInt64)
        case key(Int, UInt64)
    }

    var isEnabled = false
    var isActive: Bool { isEnabled }

    func handle(_ type: CGEventType, _ event: CGEvent) -> CGEvent? {
        guard isEnabled, type == .keyDown || type == .keyUp else { return event }
        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let app = Frontmost.bundleID
        switch Self.rewrite(keyCode: keyCode, flags: event.flags.rawValue, app: app) {
        case nil:
            return event
        case .flags(let flags):
            event.flags = CGEventFlags(rawValue: flags)
            return event
        case .key(let newKey, let flags):
            // A new key needs a fresh event so its characters match; posting after this tap
            // means it isn't seen (or snapped) by our own handlers again.
            guard let replacement = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(newKey),
                                            keyDown: type == .keyDown) else { return event }
            replacement.flags = CGEventFlags(rawValue: flags)
            replacement.post(tap: .cgSessionEventTap)
            return nil
        }
    }

    static func rewrite(keyCode: Int, flags: UInt64, app: String?) -> Rewrite? {
        let app = app ?? ""
        guard !AppLists.remote.contains(app) else { return nil }
        let held = flags & (Modifiers.control | Modifiers.command | Modifiers.option)
        switch keyCode {
        case kVK_LeftArrow, kVK_RightArrow:
            guard held == Modifiers.control else { return nil }
            return .flags(Modifiers.replace(Modifiers.control, with: Modifiers.option, in: flags))
        case kVK_Home, kVK_End:
            guard held == 0, !AppLists.terminals.contains(app) else { return nil }
            let arrow = keyCode == kVK_Home ? kVK_LeftArrow : kVK_RightArrow
            return .key(arrow, Modifiers.shiftOnly(flags) | Modifiers.command | 0x08 | Modifiers.arrowKey)
        default:
            return nil
        }
    }
}
