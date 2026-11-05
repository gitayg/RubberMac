import AppKit
import Carbon.HIToolbox

// Alt-Tab (Option on a Mac, Alt on a PC keyboard), fed by KeyboardTap:
// - windows: drives WindowSwitcher, swallowing the Tab presses; with commandTab, ⌘Tab does too, in place of the
//   macOS app switcher, so each of an app's windows can be picked;
// - apps: drives the macOS app switcher by rewriting Option to Command until Alt is released.
final class AltTabRemap: TapHandler {
    var mode: AltTabMode = .off {
        didSet {
            switching = false
            switcher.tracksFocus = mode == .windows
        }
    }

    var commandTab = false {
        didSet { switching = false }
    }

    var isActive: Bool { mode != .off }

    private let switcher: WindowSwitcher
    private var switching = false
    // The modifier holding the switch open: releasing it picks the highlighted window.
    private var holding: CGEventFlags = .maskAlternate

    // Device-specific modifier bits (IOLLEvent.h): left/right Option and left Command.
    private static let deviceOption: UInt64 = 0x20 | 0x40
    private static let deviceLeftCommand: UInt64 = 0x08

    init(switcher: WindowSwitcher) {
        self.switcher = switcher
    }

    // Returns the event to pass on (possibly rewritten), or nil to swallow it.
    func handle(_ type: CGEventType, _ event: CGEvent) -> CGEvent? {
        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        let tab = type == .keyDown && keyCode == kVK_Tab && !flags.contains(.maskControl)
        let altTab = tab && flags.contains(.maskAlternate) && !flags.contains(.maskCommand)
        let commandTab = tab && flags.contains(.maskCommand) && !flags.contains(.maskAlternate)

        switch mode {
        case .windows: return handleWindows(type, event, keyCode, flags, altTab ? .maskAlternate
                                            : commandTab && self.commandTab ? .maskCommand : nil)
        case .apps: return handleApps(type, event, flags, altTab)
        case .off: return event
        }
    }

    // The switcher does AX work, so it runs after the tap callback returns (main queue keeps order).
    // tabWith: the modifier of a Tab press that switches, nil for any other key.
    private func handleWindows(_ type: CGEventType, _ event: CGEvent, _ keyCode: Int,
                               _ flags: CGEventFlags, _ tabWith: CGEventFlags?) -> CGEvent? {
        if let tabWith, !switching || tabWith == holding {
            let reverse = flags.contains(.maskShift)
            let first = !switching
            switching = true
            holding = tabWith
            DispatchQueue.main.async { [switcher] in
                if first { switcher.begin(reverse: reverse) } else { switcher.advance(reverse: reverse) }
            }
            return nil
        }
        guard switching else { return event }
        if type == .keyUp && keyCode == kVK_Tab { return nil }
        if type == .keyDown && keyCode == kVK_Escape {
            switching = false
            DispatchQueue.main.async { [switcher] in switcher.cancel() }
            return nil
        }
        if type == .flagsChanged && !flags.contains(holding) {
            switching = false
            DispatchQueue.main.async { [switcher] in switcher.commit() }
        }
        return event
    }

    private func handleApps(_ type: CGEventType, _ event: CGEvent, _ flags: CGEventFlags, _ altTab: Bool) -> CGEvent? {
        if altTab { switching = true }
        guard switching else { return event }

        var raw = flags.rawValue
        if type == .flagsChanged && !flags.contains(.maskAlternate) {
            // Alt released: report it as Command released, which picks the highlighted app.
            switching = false
            event.setIntegerValueField(.keyboardEventKeycode, value: Int64(kVK_Command))
        } else {
            raw = (raw & ~(CGEventFlags.maskAlternate.rawValue | Self.deviceOption))
                | CGEventFlags.maskCommand.rawValue | Self.deviceLeftCommand
        }
        event.flags = CGEventFlags(rawValue: raw)
        return event
    }
}
