import AppKit
import Carbon.HIToolbox

// --selftest inputperapp-live: the real thing on this Mac's own languages. How fast a switch lands and its notice
// comes; per app with real switches and notices (the apps made up, the memory in a scratch file); then Spotlight for
// real: opened with its own shortcut as the user presses it (the switch made on the main thread while the key goes on),
// with ⌘R's way and with the ⌘ tap's Apps view, each started in the non-English language. A letter is typed once
// Spotlight has the keyboard and read back from its field, then Esc closes it and the language must come back. Once
// more with the setting off, where the same letter must come out in the other language. Puts the input source back as
// it found it; it shows Spotlight and posts keys, so it waits for an idle, ordinary desktop.
extension InputPerApp {
    static func liveSelfTestReport() -> String {
        guard AX.isTrusted else { return "skipped: accessibility not trusted" }
        guard (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool != true else {
            return "skipped: the screen is locked"
        }
        if let spaces = SpaceWindows.spaces(), !spaces.current.isDisjoint(with: spaces.fullScreen) {
            return "skipped: a full-screen app's desktop is showing; switch to an ordinary desktop and run again"
        }
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        guard idle >= 20 else { return "skipped: the Mac was in use \(Int(idle)) s ago; run it after 20 s without typing or the mouse" }
        guard !Spotlight.isOpen() else { return "skipped: Spotlight is already open; close it and run again" }
        guard let shortcut = Spotlight.searchShortcut() else { return "skipped: Spotlight's shortcut is off in System Settings" }
        guard let english = InputSources.english() else { return "skipped: no English layout is enabled" }
        guard let other = InputSources.keyboards().first(where: { !InputSources.isEnglishLayout($0) }).map(InputSources.id) else {
            return "skipped: needs a second, non-English language (like Hebrew) enabled"
        }
        return LiveTest(english: english, other: other, shortcut: shortcut).run()
    }
}

private final class LiveTest {
    let english: String, other: String, shortcut: Spotlight.Shortcut
    let start = InputSources.currentID()
    let realBefore = try? Data(contentsOf: InputPerAppStore.defaultURL)
    let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("inputperapp-live-\(getpid())/input-per-app.json")
    let source = CGEventSource(stateID: .hidSystemState)
    var lines: [String] = []
    var failures = 0
    var notices: [Date] = []

    init(english: String, other: String, shortcut: Spotlight.Shortcut) {
        self.english = english
        self.other = other
        self.shortcut = shortcut
    }

    func check(_ ok: Bool, _ what: String) {
        if !ok { failures += 1 }
        lines.append("\(ok ? "ok  " : "FAIL") \(what)")
    }

    func pump(_ seconds: TimeInterval) { RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds)) }

    // Milliseconds until the condition held, nil if it didn't within the time.
    func waitFor(_ seconds: TimeInterval, _ condition: () -> Bool) -> Int? {
        let start = Date()
        while -start.timeIntervalSinceNow < seconds {
            if condition() { return Int(-start.timeIntervalSinceNow * 1000) }
            pump(0.005)
        }
        return condition() ? Int(seconds * 1000) : nil
    }

    func ms(since date: Date) -> Int { Int(-date.timeIntervalSinceNow * 1000) }

    func run() -> String {
        lines.append("     English: \(english), other: \(other), started in \(start)")
        CFNotificationCenterAddObserver(CFNotificationCenterGetDistributedCenter(), Unmanaged.passUnretained(self).toOpaque(),
                                        { _, observer, _, _, _ in
            Unmanaged<LiveTest>.fromOpaque(observer!).takeUnretainedValue().notices.append(Date())
        }, kTISNotifySelectedKeyboardInputSourceChanged, nil, .deliverImmediately)
        try? FileManager.default.removeItem(at: scratch.deletingLastPathComponent())

        systemTiming()
        perApp()
        if failures == 0 { searches() } else { lines.append("     Spotlight not tried, as the steps before failed") }
        return finish()
    }

    func finish() -> String {
        if Spotlight.isOpen(), siriHasKeyboard() { escapeUntilClosed() }
        InputSources.select(start)
        pump(0.3)
        check(InputSources.currentID() == start, "the input source is back to \(start)")
        check((try? Data(contentsOf: InputPerAppStore.defaultURL)) == realBefore, "the real input-per-app.json is as it was")
        CFNotificationCenterRemoveEveryObserver(CFNotificationCenterGetDistributedCenter(), Unmanaged.passUnretained(self).toOpaque())
        try? FileManager.default.removeItem(at: scratch.deletingLastPathComponent())
        return (lines + [failures == 0 ? "PASS" : "FAIL: \(failures) failed"]).joined(separator: "\n")
    }

    // MARK: 1. The system

    func systemTiming() {
        InputSources.select(english)
        pump(0.3)
        notices = []
        let asked = Date()
        let landed = InputSources.select(other)
        let took = ms(since: asked)
        check(landed == other, "a switch to \(other) reads back at once when TISSelectInputSource returns (\(took) ms)")
        let notice = waitFor(1) { !notices.isEmpty }
        check(notice != nil, "its change notice reaches the process that made it" + (notice.map { ", after \($0) ms" } ?? ": none in 1 s"))
        let looked = Date()
        _ = Spotlight.isOpen()
        lines.append("     reading whether Spotlight is up takes \(String(format: "%.1f", -looked.timeIntervalSinceNow * 1000)) ms")
        InputSources.select(english)
        pump(0.3)
    }

    // MARK: 2. Per app

    func perApp() {
        let shared = InputPerApp.shared
        shared.storeURL = scratch
        shared.perAppOn = { true }
        shared.searchOn = { true }
        shared.start()
        guard let model = shared.model else { return check(false, "it starts") }
        let realFront = NSWorkspace.shared.frontmostApplication?.bundleIdentifier

        model.activated("test.a")
        check(InputSources.currentID() == english, "an app never seen keeps \(english)")
        for _ in 0..<5 where InputSources.currentID() != other { InputSources.selectNext() }
        let remembered = waitFor(1) { model.memory["test.a"] == other }
        check(remembered != nil, "a switch to \(other) as Alt-Shift makes it is remembered for that app, from its notice"
              + (remembered.map { " (after \($0) ms)" } ?? ""))
        model.activated("test.b")
        check(InputSources.currentID() == other, "another app never seen keeps \(other)")
        InputSources.select(english)
        check(waitFor(1) { model.memory["test.b"] == english } != nil, "a switch to \(english), as the menu-bar picker makes it, is remembered for that one")
        model.activated("test.a")
        check(InputSources.currentID() == other, "back in the first app, it's switched to \(other) before the call returns")
        model.activated("test.c")
        pump(0.5)
        check(model.memory == ["test.a": other, "test.b": english],
              "the notice of that switch, coming with a third app in front, is remembered for nobody: \(model.memory.sorted { $0.key < $1.key })")
        check(InputPerAppStore.load(scratch) == model.memory, "the scratch file holds the same")
        // Spotlight gives the keyboard back to the app really in front.
        model.activated(realFront)
    }

    // MARK: 3. Spotlight

    func searches() {
        let shared = InputPerApp.shared
        guard let keys = shared.keys as? InputPerAppKeys else { return check(false, "the handler is InputPerAppKeys") }
        var called: Date?, switched: Date?
        keys.onShortcut = { closes in
            called = Date()
            InputPerApp.shared.prepareForSpotlight(closes: closes)
            switched = Date()
        }
        defer { keys.onShortcut = { InputPerApp.shared.prepareForSpotlight(closes: $0) } }

        // The user's own ⌘Space: the tap's thread hands it on and the key goes to Spotlight at once.
        func pressShortcut() -> Date {
            let pressed = Date()
            DispatchQueue.global(qos: .userInteractive).async { [self] in
                let down = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(shortcut.keyCode), keyDown: true)!
                down.flags = shortcut.flags
                _ = keys.handle(.keyDown, down)
                post(modifier: true)
                for isDown in [true, false] { post(shortcut.keyCode, isDown, shortcut.flags) }
                post(modifier: false)
            }
            return pressed
        }

        called = nil; switched = nil
        trial("its own shortcut (\(shortcut.keyCode), flags \(String(shortcut.flags.rawValue, radix: 16)))", expect: "a") {
            let pressed = pressShortcut()
            return {
                guard let called, let switched else { return "the switch never ran" }
                return "the switch ran \(Int(called.timeIntervalSince(pressed) * 1000)) ms after the press and had landed "
                    + "\(Int(switched.timeIntervalSince(pressed) * 1000)) ms after it"
            }
        }

        shared.searchOn = { false }
        shared.apply()
        trial("its own shortcut with the setting off", expect: Self.typed(other)) {
            _ = pressShortcut()
            return { "" }
        }
        shared.searchOn = { true }
        shared.apply()

        trial("⌘R's way", expect: "a") { [self] in
            post(modifier: true)
            pump(0.05)
            Spotlight.openSearch(shortcut)
            let now = InputSources.currentID()
            pump(0.05)
            post(modifier: false)
            return { "\(now) already in use as the shortcut's key was posted" }
        }

        trial("the Apps view, as the ⌘ tap opens it", expect: "a") {
            Spotlight.openApps()
            let now = InputSources.currentID()
            return { "\(now) in use before Apps was asked to open" }
        }
    }

    // What the 'a' key types in that layout, read from the layout itself.
    static func typed(_ id: String) -> String {
        guard let source = InputSources.keyboards().first(where: { InputSources.id($0) == id }),
              let data = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return "?" }
        let layout = Unmanaged<CFData>.fromOpaque(data).takeUnretainedValue() as Data
        var dead: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        layout.withUnsafeBytes { bytes in
            _ = UCKeyTranslate(bytes.bindMemory(to: UCKeyboardLayout.self).baseAddress!, UInt16(kVK_ANSI_A), UInt16(kUCKeyActionDown), 0,
                               UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, 4, &length, &chars)
        }
        return String(utf16CodeUnits: chars, count: length)
    }

    // Starts in the other language, opens Spotlight one way, types 'a' once it has the keyboard, reads its field,
    // closes it with Esc and waits for the language to come back.
    func trial(_ name: String, expect: String, _ open: () -> (() -> String)) {
        guard !Spotlight.isOpen() else { return check(false, "\(name): can't tell, Spotlight is still up") }
        InputSources.select(other)
        pump(0.3)
        let note = open()
        let shown = waitFor(3) { Spotlight.isOpen() }
        let keyboard = waitFor(2) { siriHasKeyboard() }
        guard shown != nil, keyboard != nil else {
            check(false, "\(name): Spotlight came up (\(shown.map { "\($0) ms" } ?? "no")) and took the keyboard (\(keyboard.map { "\($0) ms" } ?? "no"))")
            return
        }
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none"
        lines.append("     \(name): up after \(shown ?? 0) ms, has the keyboard \(keyboard ?? 0) ms later; "
                     + "front app meanwhile: \(front); \(note())")
        post(kVK_ANSI_A, true, [])
        post(kVK_ANSI_A, false, [])
        _ = waitFor(1) { !(fieldText() ?? "").isEmpty }
        let text = fieldText()
        check(text == expect, "\(name): 'a' typed into Spotlight comes out \"\(text ?? "unreadable")\", wanted \"\(expect)\"")
        escapeUntilClosed()
        check(!Spotlight.isOpen(), "\(name): Esc closed it")
        let back = waitFor(2) { InputSources.currentID() == other }
        check(back != nil, "\(name): closed, \(other) is back" + (back.map { " after \($0) ms" } ?? " (still \(InputSources.currentID()) after 2 s)"))
        pump(0.5)
    }

    func post(_ key: Int, _ down: Bool, _ flags: CGEventFlags) {
        let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(key), keyDown: down)
        event?.flags = flags
        event?.post(tap: .cghidEventTap)
    }

    // ⌘ held while the shortcut's own key goes by, as when the user presses it.
    func post(modifier down: Bool) {
        let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Command), keyDown: down)
        event?.type = .flagsChanged
        event?.flags = down ? [.maskCommand, CGEventFlags(rawValue: 0x08)] : []
        event?.post(tap: .cghidEventTap)
    }

    // Esc goes only to Spotlight: from the Apps view the first one goes back to the search bar.
    func escapeUntilClosed() {
        for _ in 1...4 where Spotlight.isOpen() && siriHasKeyboard() {
            post(kVK_Escape, true, [])
            post(kVK_Escape, false, [])
            _ = waitFor(1) { !Spotlight.isOpen() }
        }
    }

    func focused() -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    func siriHasKeyboard() -> Bool {
        guard let element = focused() else { return false }
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        return NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == "com.apple.Siri"
    }

    func fieldText() -> String? {
        guard siriHasKeyboard(), let element = focused() else { return nil }
        return AX.string(element, kAXValueAttribute)
    }
}
