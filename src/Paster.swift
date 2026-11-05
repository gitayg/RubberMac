import AppKit
import Carbon.HIToolbox

// Puts text into another app's text box the way the user would: back to its window, then ⌘V. The text stays on
// the clipboard afterwards, to paste again somewhere else.
enum Paster {
    static func paste(_ text: String, into pid: pid_t, window: AXUIElement?) {
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(text, forType: .string)
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != pid {
            if let window { AX.focus(window, pid: pid) } else { NSRunningApplication(processIdentifier: pid)?.activate() }
        }
        whenFrontmost(pid, tries: 20) { ready in
            // Never paste into some other app; the text is on the clipboard to paste by hand.
            guard ready else { return log("writing pad: the app didn't come back to the front, left the text on the clipboard") }
            press(kVK_ANSI_V, flags: .maskCommand)
        }
    }

    private static func whenFrontmost(_ pid: pid_t, tries: Int, then go: @escaping (Bool) -> Void) {
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { go(true) }
            return
        }
        guard tries > 0 else { return go(false) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { whenFrontmost(pid, tries: tries - 1, then: go) }
    }

    // The modifiers are pressed and released as keys of their own, as on a keyboard. A key event that only carries
    // them as flags leaves the system thinking they're still held, so the next keys typed arrive as ⌘-shortcuts.
    static func press(_ key: Int, flags: CGEventFlags = []) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let modifiers = modifierKeys.filter { flags.contains($0.flag) }
        func post(_ key: Int, down: Bool, flags: CGEventFlags, type: CGEventType? = nil) {
            let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(key), keyDown: down)
            if let type { event?.type = type }
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
        }
        var held: CGEventFlags = []
        for modifier in modifiers {
            held.insert(modifier.flag)
            post(modifier.key, down: true, flags: held, type: .flagsChanged)
        }
        post(key, down: true, flags: flags)
        post(key, down: false, flags: flags)
        for modifier in modifiers.reversed() {
            held.remove(modifier.flag)
            post(modifier.key, down: false, flags: held, type: .flagsChanged)
        }
    }

    private static let modifierKeys: [(flag: CGEventFlags, key: Int)] = [
        (.maskControl, kVK_Control), (.maskAlternate, kVK_Option), (.maskShift, kVK_Shift), (.maskCommand, kVK_Command),
    ]
}
