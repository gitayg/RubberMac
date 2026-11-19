import AppKit
import Carbon.HIToolbox

// --selftest desktopkeys: which ⌃⌘←/→ presses are taken, that a taken one keeps its repeats and key-up, that no swipe
// goes past either end (on macOS 27 that wedges the Dock), how the row of desktops is read, and the swipe's events
// and payload byte for byte. Nothing moves: the handler's system side is swapped out and no event is posted.
extension DesktopKeys {
    static func selfTestReport() -> String {
        var lines: [String] = []
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            if !ok { failures += 1 }
            lines.append("\(ok ? "ok  " : "FAIL") \(what)")
        }
        func pump() { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05)) }

        // Which presses
        let arrow = Modifiers.arrowKey, controlCommand = Modifiers.control | Modifiers.command
        let leftKeys = controlCommand | 0x01 | 0x08, rightKeys = controlCommand | 0x2000 | 0x10
        let capsLock = CGEventFlags.maskAlphaShift.rawValue
        let editor = "com.apple.TextEdit"
        check(direction(keyCode: kVK_LeftArrow, flags: controlCommand | arrow, app: editor) == .left, "⌃⌘← goes left")
        check(direction(keyCode: kVK_RightArrow, flags: controlCommand | arrow, app: editor) == .right, "⌃⌘→ goes right")
        check(direction(keyCode: kVK_RightArrow, flags: leftKeys | arrow, app: editor) == .right, "with the left ⌃ and ⌘")
        check(direction(keyCode: kVK_RightArrow, flags: rightKeys | arrow, app: editor) == .right, "with the right ⌃ and ⌘")
        check(direction(keyCode: kVK_RightArrow, flags: controlCommand | arrow | capsLock, app: editor) == .right,
              "with Caps Lock on")
        check(direction(keyCode: kVK_LeftArrow, flags: controlCommand | arrow, app: nil) == .left, "with the front app not known yet")
        let others: [(UInt64, String)] = [(Modifiers.command, "⌘←, which snaps"), (Modifiers.control, "⌃←, a word back"),
                                          (Modifiers.option, "⌥←"), (0, "plain ←"),
                                          (controlCommand | Modifiers.option, "⌃⌥⌘←"),
                                          (controlCommand | Modifiers.shift, "⌃⌘⇧←"),
                                          (Modifiers.control | Modifiers.option, "⌃⌥←, which snaps in that mode")]
        for (flags, name) in others {
            check(direction(keyCode: kVK_LeftArrow, flags: flags | arrow, app: editor) == nil, "\(name) is left alone")
        }
        for (key, name) in [(kVK_UpArrow, "⌃⌘↑"), (kVK_DownArrow, "⌃⌘↓"), (kVK_ANSI_F, "⌃⌘F, full screen")] {
            check(direction(keyCode: key, flags: controlCommand | arrow, app: editor) == nil, "\(name) is left alone")
        }
        let remoteKept = AppLists.remote.filter { direction(keyCode: kVK_RightArrow, flags: controlCommand | arrow, app: $0) != nil }
        check(remoteKept.isEmpty, "⌃⌘→ is left to all \(AppLists.remote.count) remote desktops and VMs"
              + (remoteKept.isEmpty ? "" : "; taken in: " + remoteKept.sorted().joined(separator: ", ")))

        // The handler, with its system side swapped out.
        let handler = DesktopKeys()
        handler.isEnabled = true
        var moves: [Direction] = []
        var front: String? = editor
        handler.onMove = { moves.append($0) }
        handler.frontmost = { front }
        let source = CGEventSource(stateID: .privateState)
        func key(_ code: Int, _ down: Bool, _ flags: UInt64, repeating: Bool = false) -> CGEvent? {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(code), keyDown: down) else { return nil }
            event.flags = CGEventFlags(rawValue: flags | arrow)
            if repeating { event.setIntegerValueField(.keyboardEventAutorepeat, value: 1) }
            return handler.handle(down ? .keyDown : .keyUp, event)
        }
        check(key(kVK_RightArrow, true, controlCommand) == nil, "⌃⌘→'s key-down is swallowed")
        check(key(kVK_RightArrow, true, controlCommand, repeating: true) == nil
              && key(kVK_RightArrow, true, controlCommand, repeating: true) == nil, "so are its repeats")
        check(key(kVK_RightArrow, false, controlCommand) == nil, "and its key-up")
        pump()
        check(moves == [.right], "held with two repeats, it moves one desktop right (\(moves))")
        moves = []
        check(key(kVK_LeftArrow, true, controlCommand) == nil, "⌃⌘← is swallowed")
        check(key(kVK_LeftArrow, false, 0) == nil, "its key-up is swallowed even with ⌃⌘ let go first")
        pump()
        check(moves == [.left], "it moves one desktop left (\(moves))")
        moves = []
        check(key(kVK_RightArrow, false, controlCommand) != nil, "a key-up whose key-down wasn't taken goes on")
        check(key(kVK_RightArrow, true, controlCommand, repeating: true) != nil, "so does a repeat whose press wasn't taken")
        check(key(kVK_LeftArrow, true, Modifiers.control) != nil && key(kVK_LeftArrow, false, Modifiers.control) != nil,
              "⌃← goes on, for the word jump")
        front = "com.microsoft.rdc.macos"
        check(key(kVK_RightArrow, true, controlCommand) != nil && key(kVK_RightArrow, false, controlCommand) != nil,
              "in a remote desktop, ⌃⌘→ goes to it")
        front = editor
        _ = key(kVK_RightArrow, true, controlCommand)
        handler.tapWasDisabled()
        check(key(kVK_RightArrow, false, controlCommand) != nil, "after the tap was switched off, a key-up from before goes on")
        pump()
        moves = []
        handler.isEnabled = false
        check(key(kVK_RightArrow, true, controlCommand) != nil && key(kVK_RightArrow, false, controlCommand) != nil,
              "switched off, ⌃⌘→ goes to the app")
        pump()
        check(moves.isEmpty, "and nothing moves (\(moves))")

        // The ends: a swipe past either one wedges the Dock, so none is made.
        let three = Desktops.Row(display: "A", spaces: [11, 12, 13], index: 0)
        let middle = Desktops.Row(display: "A", spaces: [11, 12, 13], index: 1)
        let last = Desktops.Row(display: "A", spaces: [11, 12, 13], index: 2)
        let one = Desktops.Row(display: "A", spaces: [11], index: 0)
        check(Desktops.target(three, .left, heading: nil) == nil, "on the first of three, ⌃⌘← stays")
        check(Desktops.target(three, .right, heading: nil) == 1, "on the first, ⌃⌘→ goes to the second")
        check(Desktops.target(middle, .left, heading: nil) == 0 && Desktops.target(middle, .right, heading: nil) == 2,
              "from the middle, either way")
        check(Desktops.target(last, .right, heading: nil) == nil, "on the last, ⌃⌘→ stays")
        check(Desktops.target(one, .left, heading: nil) == nil && Desktops.target(one, .right, heading: nil) == nil,
              "with one desktop, neither moves")
        check(Desktops.target(middle, .right, heading: 2) == nil,
              "a second ⌃⌘→ while the window server still says the middle, after a swipe to the last: stays")
        check(Desktops.target(three, .right, heading: 1) == 2, "a quick second ⌃⌘→ from the first goes to the third")
        let now = Date()
        let swiped = (display: "A", index: 2, at: now)
        check(Desktops.headingIndex(swiped, for: middle, now: now.addingTimeInterval(0.5)) == 2, "where a swipe went counts for 0.5 s")
        check(Desktops.headingIndex(swiped, for: middle, now: now.addingTimeInterval(1)) == nil, "but not after 1 s")
        check(Desktops.headingIndex((display: "B", index: 2, at: now), for: middle, now: now) == nil, "nor on another screen")
        check(Desktops.headingIndex(nil, for: middle, now: now) == nil, "and there's none before a swipe")

        // Reading the row
        func space(_ id: UInt64, type: Int = 0) -> [String: Any] { ["ManagedSpaceID": NSNumber(value: id), "type": type] }
        func display(_ name: String, _ ids: [UInt64], current: UInt64?) -> [String: Any] {
            var entry: [String: Any] = ["Display Identifier": name, "Spaces": ids.map { space($0) }]
            if let current { entry["Current Space"] = space(current) }
            return entry
        }
        let two = [display("Left", [1, 2], current: 2), display("Right", [3, 4, 5], current: 4)]
        check(Desktops.row(in: two, menuBarDisplay: "Right", active: 2) == Desktops.Row(display: "Right", spaces: [3, 4, 5], index: 1),
              "two screens: the one with the menu bar, on its own current Space")
        check(Desktops.row(in: two, menuBarDisplay: nil, active: nil)?.display == "Left", "menu bar not known: the first screen")
        check(Desktops.row(in: [display("Main", [7, 8], current: nil)], menuBarDisplay: "Main", active: 8)?.index == 1,
              "no current Space named: the active one")
        check(Desktops.row(in: [display("Main", [7, 8], current: 9)], menuBarDisplay: "Main", active: 9) == nil,
              "a current Space not in the row: unreadable, so no swipe")
        check(Desktops.row(in: [], menuBarDisplay: nil, active: 1) == nil, "no screens: unreadable")
        let id64 = [["Display Identifier": "Main", "Spaces": [["id64": NSNumber(value: 21)], ["id64": NSNumber(value: 22)]],
                     "Current Space": ["id64": NSNumber(value: 22)]] as [String: Any]]
        check(Desktops.row(in: id64, menuBarDisplay: "Main", active: nil)?.index == 1, "Spaces named only by id64 are read too")
        let mine = Desktops.row()
        lines.append("note: this Mac: \(mine.map { "\($0.spaces.count) Spaces on the menu bar's screen, on number \($0.index + 1)" } ?? "unreadable")")

        // The swipe
        check(DesktopSwipe.sign(.right, naturalScrolling: true) == -1 && DesktopSwipe.sign(.left, naturalScrolling: true) == 1,
              "natural scrolling on: right is negative")
        check(DesktopSwipe.sign(.right, naturalScrolling: false) == 1 && DesktopSwipe.sign(.left, naturalScrolling: false) == -1,
              "natural scrolling off: right is positive")
        lines.append("note: this Mac's natural scrolling is \(DesktopSwipe.naturalScrolling() ? "on" : "off")")
        let fixedCases: [(Double, Int32)] = [(0.000016, 1), (-0.000016, -1), (0.1, 6553), (9999, 655_294_464), (-9999, -655_294_464),
                                             (0, 0), (1, 65536)]
        let wrongFixed = fixedCases.filter { DesktopSwipe.fixed($0.0) != $0.1 }
        check(wrongFixed.isEmpty, "16.16 fixed point, tiny values kept as ±1"
              + (wrongFixed.isEmpty ? "" : ": " + wrongFixed.map { "\($0.0) → \(DesktopSwipe.fixed($0.0)), not \($0.1)" }.joined(separator: ", ")))

        func u32(_ bytes: [UInt8], _ at: Int) -> UInt32 { bytes[at..<at + 4].reversed().reduce(0) { $0 << 8 | UInt32($1) } }
        func i32(_ bytes: [UInt8], _ at: Int) -> Int32 { Int32(bitPattern: u32(bytes, at)) }
        func u16(_ bytes: [UInt8], _ at: Int) -> UInt16 { UInt16(bytes[at]) | UInt16(bytes[at + 1]) << 8 }
        for (phase, name) in [(DesktopSwipe.began, "began"), (DesktopSwipe.changed, "changed"), (DesktopSwipe.ended, "ended")] {
            guard let pair = DesktopSwipe.events(phase: phase, sign: -1) else {
                check(false, "\(name): the events are made (the event format is the version 2 the payload is added to)")
                continue
            }
            let dock = pair.dock, isEnd = phase == DesktopSwipe.ended
            check(dock.getIntegerValueField(DesktopSwipe.eventType) == 30 && dock.getIntegerValueField(DesktopSwipe.hidType) == 23
                  && dock.getIntegerValueField(DesktopSwipe.phase) == phase && dock.getIntegerValueField(DesktopSwipe.motion) == 1,
                  "\(name): a DockControl event, a Dock swipe, horizontal, in that phase, after the payload was added")
            check(pair.companion.getIntegerValueField(DesktopSwipe.eventType) == 29, "\(name): with a Gesture event beside it")
            let velocity = dock.getDoubleValueField(DesktopSwipe.velocityX)
            check(isEnd ? velocity < -9000 : velocity == 0, "\(name): \(isEnd ? "flung left at" : "no velocity,") \(velocity)")
            let bytes = DesktopSwipe.payload(of: dock)
            let size = isEnd ? 96 : 68
            check(bytes.count == size, "\(name): the payload is \(size) bytes (\(bytes.count))")
            guard bytes.count == size else { continue }
            check(u32(bytes, 24) == (isEnd ? 2 : 1), "\(name): the header counts \(isEnd ? 2 : 1) event(s)")
            check(u32(bytes, 28) == 40 && u32(bytes, 32) == 23 && u32(bytes, 36) == UInt32(phase) << 24 && bytes[40] == 0,
                  "\(name): a 40-byte fluid touch gesture, its phase in the options")
            check(i32(bytes, 44) == 6553 && i32(bytes, 48) == 0 && u16(bytes, 60) == 1 && u16(bytes, 62) == 3 && i32(bytes, 64) == -1,
                  "\(name): at x 0.1, horizontal, the Dock's primary flavour, progress -1/65536")
            if isEnd {
                check(u32(bytes, 68) == 28 && u32(bytes, 72) == 9 && bytes[80] == 1 && i32(bytes, 84) == DesktopSwipe.fixed(velocity)
                      && i32(bytes, 88) == 0, "ended: then a 28-byte velocity event with the fling")
            }
        }
        if let plain = CGEvent(source: nil), let data = plain.data as Data? {
            check(Array(data.prefix(4)) == [0, 0, 0, 2], "this macOS writes events in format version 2 (\(Array(data.prefix(4))))")
        }

        return (lines + [failures == 0 ? "PASS" : "FAIL: \(failures) failed"]).joined(separator: "\n")
    }
}
