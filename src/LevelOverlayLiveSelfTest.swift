import AppKit

// --selftest overlay-live: the real thing on this Mac. Which output device sound goes to and whether its volume can be
// set (so whether the volume keys are taken), the volume calls on another output device nothing plays to (set and put
// back exactly), the level window on each real screen (where it lands, that it takes no click or focus, updates in place
// and fades), ⌃⌥⌘↑ showing it on each screen it changed, and a real brightness key posted through a real tap: read,
// taken for the screen under the pointer and kept from macOS. Never sets the volume sound goes to, and puts back any
// brightness it changed. It shows windows and posts keys, so it waits for an idle, ordinary desktop.
extension LevelOverlay {
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

        var lines: [String] = []
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            if !ok { failures += 1 }
            lines.append("\(ok ? "ok  " : "FAIL") \(what)")
        }
        func note(_ text: String) { lines.append("note: " + text) }
        NSApp.setActivationPolicy(.accessory)
        let domain = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName
        let stored = UserDefaults.standard.persistentDomain(forName: domain) as NSDictionary?
        let output = OutputVolume.current
        let volume = output?.volume, muted = output?.isMuted

        thisMac(output, note)
        volumeCalls(output, check, note)
        windowChecks(check, note)
        hotKeyChecks(check, note)
        tapChecks(check, note)

        // By name: a device's number changes when macOS lists the devices again, as when a dock is unplugged.
        let now = OutputVolume.current
        check(now?.name == output?.name && now?.volume == volume && now?.isMuted == muted,
              "the output sound goes to is as it was: \(describe(output, volume, muted)), now \(describe(now, now?.volume, now?.isMuted))")
        let after = UserDefaults.standard.persistentDomain(forName: domain) as NSDictionary?
        let changed = Set((stored?.allKeys ?? []) + (after?.allKeys ?? []) as? [String] ?? []).filter {
            (stored?[$0] as? NSObject) != (after?[$0] as? NSObject)
        }
        check(changed.isEmpty, "no stored setting changed" + (changed.isEmpty ? "" : "; changed: \(changed.sorted().joined(separator: ", "))"))
        return (lines + [failures == 0 ? "PASS" : "FAIL: \(failures) failed"]).joined(separator: "\n")
    }

    typealias LiveCheck = (Bool, String) -> Void

    private static func describe(_ output: OutputVolume?, _ volume: Float?, _ muted: Bool?) -> String {
        guard let output else { return "none" }
        return "\(output.name) at \(volume.map { "\($0)" } ?? "?")\(muted == true ? ", muted" : "")"
    }

    static func pump(_ seconds: TimeInterval) {
        let until = Date(timeIntervalSinceNow: seconds)
        repeat {
            if let event = NSApp.nextEvent(matching: .any, until: min(until, Date(timeIntervalSinceNow: 0.01)), inMode: .default, dequeue: true) {
                NSApp.sendEvent(event)
            }
        } while Date() < until
    }

    // Milliseconds until the condition held, nil if it didn't within the time.
    static func waitFor(_ seconds: TimeInterval, _ condition: () -> Bool) -> Int? {
        let start = Date()
        while -start.timeIntervalSinceNow < seconds {
            if condition() { return Int(-start.timeIntervalSinceNow * 1000) }
            pump(0.01)
        }
        return condition() ? Int(seconds * 1000) : nil
    }

    // MARK: 1. This Mac

    private static func thisMac(_ output: OutputVolume?, _ note: (String) -> Void) {
        if let output {
            note("sound goes to \"\(output.name)\" (transport \(output.transport)): volume can be set \(output.canSetVolume), mute \(output.canMute)"
                         + ", so the volume keys are \(output.canSetVolume ? "taken" : "left to macOS")")
        } else {
            note("no output device, so the volume keys are left to macOS")
        }
        let others = OutputVolume.all.filter { $0.device != output?.device }
        note("other outputs: " + others.map { "\($0.name) (\($0.transport), \($0.canSetVolume ? "settable" : "not settable"))" }.joined(separator: ", "))
        let pointer = MediaKeys.displayUnderPointer()
        let screens = NSScreen.screens.map { screen -> String in
            let id = screen.displayID ?? 0
            return "\(screen.localizedName) (id \(id), \(CGDisplayIsBuiltin(id) != 0 ? "built in" : "external"), vendor 0x\(String(CGDisplayVendorNumber(id), radix: 16)), "
                + "brightness \(MediaKeys.macOSSetsBrightness(id) ? "set by macOS" : "RubberMAC's")\(id == pointer ? ", pointer here" : ""))"
        }
        let taken = pointer.map { !MediaKeys.macOSSetsBrightness($0) } == true
        note("screens: " + screens.joined(separator: ", ") + "; brightness keys are \(taken ? "taken" : "left to macOS") here")
    }

    // MARK: 2. The volume calls, on a device nothing plays to

    private static func volumeCalls(_ output: OutputVolume?, _ check: LiveCheck, _ note: (String) -> Void) {
        guard let spare = OutputVolume.all.first(where: { $0.device != output?.device && $0.canSetVolume }), let before = spare.volume else {
            note("no other output device with a volume to try the calls on")
            return
        }
        let target = LevelSteps.volume(before, up: before < 0.5, fine: false)
        let wrote = spare.setVolume(target)
        let read = waitFor(1) { spare.volume.map { abs($0 - target) < 0.002 } == true }
        let reading = spare.volume
        let putBack = spare.setVolume(before)
        let back = waitFor(1) { spare.volume == before }
        check(wrote && read != nil, "\(spare.name): volume \(before) set to the next step, \(target), reads \(reading.map { "\($0)" } ?? "nothing")")
        check(putBack && back != nil, "and put back: reads \(spare.volume.map { "\($0)" } ?? "nothing") again")
        guard spare.canMute, let muted = spare.isMuted else { return }
        let switched = spare.setMuted(!muted) && waitFor(1) { spare.isMuted == !muted } != nil
        let restored = spare.setMuted(muted) && waitFor(1) { spare.isMuted == muted } != nil
        check(switched && restored, "its mute switched to \(!muted) and back to \(muted)")
    }

    // MARK: 3. The window on each screen

    private static func windowChecks(_ check: LiveCheck, _ note: (String) -> Void) {
        let windows = LevelOverlayWindows()
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let screens = NSScreen.screens.compactMap { screen in screen.displayID.map { (screen, $0) } }
        screens.forEach { windows.show(symbol: "speaker.wave.2.fill", level: 0.5, on: $0.0) }
        var shownAt = Date()
        let shown = waitFor(1) { screens.allSatisfy { onScreen(windows.panel(for: $0.1).windowNumber) != nil } }
        check(shown != nil, "a level window comes up on each of \(screens.count) screen(s)\(shown.map { " within \($0) ms" } ?? "")")
        for (screen, id) in screens {
            let panel = windows.panel(for: id)
            let expected = LevelOverlayWindows.frame(screen: screen.frame, visible: screen.visibleFrame)
            let info = onScreen(panel.windowNumber)
            let flipped = CGRect(x: expected.minX, y: NSScreen.screens[0].frame.maxY - expected.maxY, width: expected.width, height: expected.height)
            check(panel.frame == expected && info.map { abs($0.bounds.midX - flipped.midX) < 1 && abs($0.bounds.midY - flipped.midY) < 1 } == true
                  && screen.frame.contains(expected) && expected.maxY < screen.frame.minY + screen.frame.height / 3,
                  "\(screen.localizedName) (\(screen.frame)): centred low on that screen, frame \(panel.frame), "
                  + "the window server has it at \(info.map { "\($0.bounds)" } ?? "nowhere")")
            check(info?.layer == Int(LevelOverlayWindows.level.rawValue), "above other windows and the dimming (layer \(info.map { "\($0.layer)" } ?? "?"))")
            let hit = NSWindow.windowNumber(at: NSPoint(x: expected.midX, y: expected.midY), belowWindowWithWindowNumber: 0)
            check(hit != panel.windowNumber, "a click on it goes to the window under it (window \(hit), not \(panel.windowNumber))")
        }
        check(NSWorkspace.shared.frontmostApplication?.processIdentifier == front && !NSApp.isActive && NSApp.keyWindow == nil,
              "the app in front stays in front and nothing of RubberMAC's has the keyboard")

        guard let first = screens.first else { return }
        let (screen, id) = first
        let panel = windows.panel(for: id), number = panel.windowNumber
        pump(0.8)
        windows.show(symbol: "speaker.wave.3.fill", level: 0.75, on: screen)
        shownAt = Date()
        let ours = { (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []).filter {
            $0[kCGWindowOwnerPID as String] as? Int32 == ProcessInfo.processInfo.processIdentifier
                && ($0[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) }
                    .map { screenRect(screen).contains($0) } == true
        }.count }
        pump(0.1)
        check(windows.panel(for: id).windowNumber == number && panel.content.bar.level == 0.75 && ours() == 1,
              "a second change on the same screen updates the same window (\(number)) in place: one window of ours there")
        let stillUp = waitFor(max(0, 1.2 + shownAt.timeIntervalSinceNow)) { onScreen(number) == nil } == nil
        let gone = waitFor(1.5) { onScreen(number) == nil }
        let after = Int(-shownAt.timeIntervalSinceNow * 1000)
        check(stillUp && gone != nil, "it stays up 1.2 s after the last change and is gone \(gone == nil ? "never (2.7 s)" : "\(after) ms after it")")

        windows.show(symbol: LevelSteps.brightnessSymbol, level: 0.3, on: screen)
        pump(LevelOverlayWindows.shownFor + 0.12)
        let fading = onScreen(number)?.alpha ?? 0
        windows.show(symbol: LevelSteps.brightnessSymbol, level: 0.4, on: screen)
        pump(1.0)
        let again = onScreen(number)?.alpha
        check(fading < 1 && again == 1, "a change while it fades (alpha \(String(format: "%.2f", fading))) brings it back in full (alpha \(again.map { "\($0)" } ?? "gone"))")
        _ = waitFor(2) { onScreen(number) == nil }
    }

    private static func screenRect(_ screen: NSScreen) -> CGRect {
        CGRect(x: screen.frame.minX, y: NSScreen.screens[0].frame.maxY - screen.frame.maxY, width: screen.frame.width, height: screen.frame.height)
    }

    // The window as the window server has it, nil when it's not on screen.
    static func onScreen(_ number: Int) -> (bounds: CGRect, layer: Int, alpha: Double)? {
        guard number > 0, let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(number)) as? [[String: Any]])?.first,
              info[kCGWindowIsOnscreen as String] as? Bool == true,
              let bounds = (info[kCGWindowBounds as String] as? NSDictionary).flatMap({ CGRect(dictionaryRepresentation: $0 as CFDictionary) })
        else { return nil }
        return (bounds, info[kCGWindowLayer as String] as? Int ?? 0, info[kCGWindowAlpha as String] as? Double ?? 0)
    }

    // MARK: 4. ⌃⌥⌘↑

    private static func hotKeyChecks(_ check: LiveCheck, _ note: (String) -> Void) {
        let brightness = Brightness()
        var refreshed = false
        brightness.refresh { refreshed = true }
        _ = waitFor(3) { refreshed }
        let levels = brightness.levels
        let saved = UserDefaults.standard.dictionary(forKey: "softwareBrightness") as NSDictionary?
        let overlay = LevelOverlay()
        overlay.brightness = brightness
        overlay.start()
        // Its own tap isn't wanted here: section 5 uses one whose steps change nothing.
        overlay.keys.isEnabled = false
        overlay.restartTaps()
        let wired = brightness.onStep
        var stepped: [(CGDirectDisplayID, Int)] = []
        brightness.onStep = { id, level in
            stepped.append((id, level))
            wired?(id, level)
        }
        check(wired != nil, "start() hands Brightness where to show the hotkeys' steps")
        note("levels before ⌃⌥⌘↑: " + brightness.displays.map { "\($0.name) \(levels[$0.id] ?? -1)% (\($0.hardware ? "DDC" : "software"))" }.joined(separator: ", "))
        brightness.stepAll(1)
        _ = waitFor(3) { stepped.count >= brightness.displays.count }
        pump(0.2)
        check(stepped.map(\.0) == brightness.displays.map(\.id) && stepped.allSatisfy { $0.1 == min((levels[$0.0] ?? 100) + Brightness.step, 100) },
              "⌃⌥⌘↑ steps each of \(brightness.displays.count) screen(s): " + stepped.map { "\($0.0) → \($0.1)%" }.joined(separator: ", "))
        if Settings.levelOverlayEnabled {
            for (id, level) in stepped {
                let panel = overlay.windows.panel(for: id)
                check(onScreen(panel.windowNumber) != nil && panel.content.bar.level == Double(level) / 100,
                      "and the level window shows \(level)% on screen \(id)")
            }
        } else {
            note("the setting is off here, so ⌃⌥⌘↑ shows nothing, as it should")
        }
        // A brightness key's own path, on a screen already at full so nothing changes.
        if Settings.levelOverlayEnabled, let full = brightness.displays.first(where: { brightness.levels[$0.id] == 100 }) {
            let panel = overlay.windows.panel(for: full.id)
            panel.content.bar.level = 0
            overlay.perform(MediaKeys.Press(key: .brightnessUp, fine: false, display: full.id))
            pump(0.2)
            check(brightness.levels[full.id] == 100 && onScreen(panel.windowNumber) != nil && panel.content.bar.level == 1,
                  "brightness up on \(full.name), already at full, keeps it there and shows it full")
        }
        for display in brightness.displays where brightness.levels[display.id] != levels[display.id] {
            brightness.set(levels[display.id] ?? 100, for: display.id)
        }
        pump(0.3)
        let savedAfter = UserDefaults.standard.dictionary(forKey: "softwareBrightness") as NSDictionary?
        if savedAfter != saved {
            if let saved { UserDefaults.standard.set(saved, forKey: "softwareBrightness") } else { UserDefaults.standard.removeObject(forKey: "softwareBrightness") }
        }
        check(brightness.levels == levels && savedAfter == saved, "every screen's brightness, and the saved levels, are as before"
              + (savedAfter == saved ? "" : " (the saved levels had changed and were put back)"))
        _ = waitFor(2.5) { stepped.allSatisfy { onScreen(overlay.windows.panel(for: $0.0).windowNumber) == nil } }
    }

    // MARK: 5. A real key through a real tap

    private static func tapChecks(_ check: LiveCheck, _ note: (String) -> Void) {
        let raw = RawKeys()
        let handler = MediaKeys()
        var presses: [MediaKeys.Press] = []
        handler.isEnabled = true
        // A volume key pressed while it runs stays macOS's; a brightness key is only noted.
        handler.canSetVolume = { false }
        handler.canMute = { false }
        handler.onPress = { presses.append($0) }
        let tap = EventTap(name: "media keys self-test", types: [MediaKeys.systemDefined], location: .cgSessionEventTap,
                           ownThread: true, handlers: [raw, handler])
        tap.update()
        let tail = TailListener()
        defer {
            handler.isEnabled = false
            tap.update()
            tail.stop()
        }
        check(tap.isRunning && tail.isRunning, "a tap on system-defined events at the head, and one listening at the tail")

        // An aux key no Mac has, so it does nothing wherever it goes. It shows who can post keys our taps see.
        let unused = [MediaKeys.Event(code: 0x7F, down: true, repeating: false), MediaKeys.Event(code: 0x7F, down: false, repeating: false)]
        func reached(_ code: Int) -> Bool { waitFor(1.5) { tail.seen.filter { $0.code == code }.count >= 2 } != nil }
        post(unused.map(\.data1))
        guard reached(0x7F) else {
            check(false, "an unused aux key this process posted never reached its taps, so no brightness key was posted")
            return
        }
        let seen = raw.seen.filter { $0.code == 0x7F }
        check(seen.map(\.data1) == unused.map(\.data1) && seen.allSatisfy { $0.subtype == 8 },
              "the head tap reads it as subtype 8, data1 " + seen.map { String(format: "0x%06X", $0.data1) }.joined(separator: " then "))

        guard let display = MediaKeys.displayUnderPointer(), !MediaKeys.macOSSetsBrightness(display) else {
            note("the pointer is on a screen whose brightness macOS sets, so no brightness key was posted")
            return
        }
        let brightnessDown = [MediaKeys.Event(code: 3, down: true, repeating: false), MediaKeys.Event(code: 3, down: false, repeating: false)]
        post(brightnessDown.map(\.data1))
        _ = waitFor(1.5) { raw.seen.filter { $0.code == 3 }.count >= 2 && !presses.isEmpty }
        pump(0.3)
        let read = raw.seen.filter { $0.code == 3 }
        check(read.map(\.data1) == brightnessDown.map(\.data1), "a posted brightness down arrives as data1 " + read.map { String(format: "0x%06X", $0.data1) }.joined(separator: " then "))
        check(presses == [MediaKeys.Press(key: .brightnessDown, fine: false, display: display)],
              "and is taken as one brightness-down step for the screen under the pointer (\(display)): \(presses.count) step(s)")
        check(tail.seen.filter { $0.code == 3 }.isEmpty && tail.seen.filter { $0.code == 0x7F }.count == 2,
              "macOS never saw it, down or up: the tail tap saw the unused key but not this one")
    }

    // Unlike key presses, system-defined events this process posts do reach its own taps on this macOS.
    private static func post(_ data1s: [Int]) {
        for data1 in data1s {
            guard let event = MediaKeys.Event(data1: data1), let cg = MediaKeys.event(event) else { continue }
            cg.post(tap: .cghidEventTap)
            usleep(50_000)
        }
    }
}

// Every aux-control event the head tap sees, as it arrives; passes them all on.
private final class RawKeys: TapHandler {
    struct Seen {
        let code: Int
        let data1: Int
        let subtype: Int16
    }

    private(set) var seen: [Seen] = []
    var isActive: Bool { true }

    func handle(_ type: CGEventType, _ event: CGEvent) -> CGEvent? {
        guard let ns = NSEvent(cgEvent: event), ns.type == .systemDefined else { return event }
        let item = Seen(code: (ns.data1 >> 16) & 0xFFFF, data1: ns.data1, subtype: ns.subtype.rawValue)
        DispatchQueue.main.async { self.seen.append(item) }
        return event
    }
}

// A listen-only tap at the tail, after every other: what it sees went past the head tap untaken.
private final class TailListener {
    private(set) var seen: [MediaKeys.Event] = []
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    var isRunning: Bool { tap != nil }

    init() {
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
                                eventsOfInterest: 1 << MediaKeys.systemDefined.rawValue, callback: { _, _, event, info in
            let listener = Unmanaged<TailListener>.fromOpaque(info!).takeUnretainedValue()
            if let key = MediaKeys.decode(event) { listener.seen.append(key) }
            return Unmanaged.passUnretained(event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque())
        guard let tap else { return }
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    }

    func stop() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        self.tap = nil
    }
}
