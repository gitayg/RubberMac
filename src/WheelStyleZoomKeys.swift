import AppKit
import Carbon.HIToolbox

// Presses a zoom item's own shortcut in its app, or the item itself when the shortcut can't be typed.
enum ZoomKeys {
    struct Stroke: Equatable {
        var code: CGKeyCode
        var flags: CGEventFlags
        // What the key types with ⇧ or without, as a real press carries it: + for ⌘⇧=, > for ⇧⌘.
        var character: String
    }

    // The key that types the character, ⇧ if it needs it, and the item's own modifiers. Some apps show the minus key
    // as a minus sign.
    static func stroke(for item: ZoomItem) -> Stroke? {
        guard let shown = item.key, item.modifiers & 8 == 0 else { return nil }
        guard let key = key(shown == "−" ? "-" : shown) else { return nil }
        var flags = CGEventFlags.maskCommand
        let shift = key.shift || item.modifiers & 1 != 0
        if shift { flags.insert(.maskShift) }
        if item.modifiers & 2 != 0 { flags.insert(.maskAlternate) }
        if item.modifiers & 4 != 0 { flags.insert(.maskControl) }
        guard let typed = typed(key.code, shift: shift) else { return nil }
        return Stroke(code: key.code, flags: flags, character: typed)
    }

    // To the app's own process, so it lands there even if another app comes forward meanwhile.
    static func press(_ item: ZoomItem, in pid: pid_t) {
        guard let stroke = stroke(for: item) else {
            // Off the tap's thread, which a busy app could otherwise hold up for as long as it takes to answer.
            guard let element = item.element else { return }
            DispatchQueue.global(qos: .userInitiated).async {
                AXUIElementSetMessagingTimeout(element, 0.5)
                AXUIElementPerformAction(element, kAXPressAction as CFString)
            }
            return
        }
        var characters = Array(stroke.character.utf16)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: stroke.code, keyDown: down) else { continue }
            event.flags = stroke.flags
            event.keyboardSetUnicodeString(stringLength: characters.count, unicodeString: &characters)
            event.postToPid(pid)
        }
    }

    // Main keys only (codes under 64): the keypad's + and = would be found first, and aren't the shortcut.
    static func key(_ character: String) -> (code: CGKeyCode, shift: Bool)? {
        guard let layout = layout() else { return nil }
        for shift in [false, true] {
            for code in 0..<CGKeyCode(64) where typed(code, shift: shift, layout) == character { return (code, shift) }
        }
        return nil
    }

    static func typed(_ code: CGKeyCode, shift: Bool) -> String? {
        layout().flatMap { typed(code, shift: shift, $0) }
    }

    // The Latin layout in use (U.S., ABC, British…), the one ⌘ shortcuts go by with Hebrew on too.
    private static func layout() -> Data? {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let data = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        return Unmanaged<CFData>.fromOpaque(data).takeUnretainedValue() as Data
    }

    private static func typed(_ code: CGKeyCode, shift: Bool, _ layout: Data) -> String? {
        layout.withUnsafeBytes { bytes -> String? in
            var dead: UInt32 = 0
            var chars = [UniChar](repeating: 0, count: 4)
            var length = 0
            let state = shift ? UInt32(shiftKey >> 8) & 0xFF : 0
            guard UCKeyTranslate(bytes.bindMemory(to: UCKeyboardLayout.self).baseAddress!, code, UInt16(kUCKeyActionDown), state,
                                 UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, 4, &length, &chars) == noErr,
                  length > 0 else { return nil }
            return String(utf16CodeUnits: chars, count: length)
        }
    }
}
