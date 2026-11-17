import AppKit

// --selftest overlay: how a volume or brightness key is read from its event, which ones are taken (and that a taken
// one keeps its repeats and key-up), the steps the keys move through, the level window drawn off screen in light and
// dark (to PNGs in a folder), and the settings row. Hands made-up events straight to the handler with its system side
// swapped out, so no volume, brightness or window changes, and no stored setting either.
extension LevelOverlay {
    static func selfTestReport() -> String {
        var lines: [String] = []
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            if !ok { failures += 1 }
            lines.append("\(ok ? "ok  " : "FAIL") \(what)")
        }
        func note(_ text: String) { lines.append("note: " + text) }
        NSApp.setActivationPolicy(.accessory)
        let stored = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName) as NSDictionary?

        decodeChecks(check, note)
        handlerChecks(check)
        screenChecks(check, note)
        stepChecks(check)
        windowChecks(check, note)
        settingsChecks(check, note)

        let after = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName) as NSDictionary?
        check(stored?.isEqual(after) ?? (after == nil), "no stored setting changed")
        return (lines + [failures == 0 ? "PASS" : "FAIL: \(failures) failed"]).joined(separator: "\n")
    }

    typealias Check = (Bool, String) -> Void

    // MARK: Reading the event

    private static func decodeChecks(_ check: Check, _ note: (String) -> Void) {
        let keys: [(MediaKeys.Key, String)] = [(.volumeUp, "volume up"), (.volumeDown, "volume down"), (.mute, "mute"),
                                               (.brightnessUp, "brightness up"), (.brightnessDown, "brightness down")]
        var layout: [String] = []
        for (key, name) in keys {
            for (down, repeating) in [(true, false), (true, true), (false, false)] {
                let made = MediaKeys.Event(code: key.rawValue, down: down, repeating: repeating)
                let event = MediaKeys.event(made)
                let read = event.flatMap(MediaKeys.decode)
                check(event?.type == MediaKeys.systemDefined && read == made,
                      "\(name) \(down ? (repeating ? "repeat" : "down") : "up") reads back as code \(key.rawValue) from data1 "
                      + String(format: "0x%06X", made.data1))
                if !repeating && down { layout.append("\(name) 0x" + String(made.data1, radix: 16, uppercase: true)) }
            }
        }
        note("data1 for a press (code << 16 | 0x0A00 down / 0x0B00 up | 1 repeat): " + layout.joined(separator: ", "))
        check(MediaKeys.Event(data1: 0x07_0000) == nil && MediaKeys.Event(data1: 0x07_0C00) == nil,
              "data1 with a state other than 0x0A or 0x0B isn't a key")
        let mouseButtons = NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                              context: nil, subtype: 7, data1: 0x0A00, data2: 1)?.cgEvent
        check(mouseButtons.map(MediaKeys.decode) == .some(nil), "a system-defined event of another subtype (7, mouse buttons) isn't a key")
        let letter = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)!
        check(MediaKeys.decode(letter) == nil, "an ordinary key press isn't one either")
    }

    // MARK: Which keys are taken

    private static func handlerChecks(_ check: Check) {
        let handler = MediaKeys()
        handler.isEnabled = true
        var settable = true, mutable = true
        var pointer: CGDirectDisplayID? = 7
        var presses: [MediaKeys.Press] = []
        // Made-up screens: 1 built in, 7 a Dell, 8 a Studio Display (left unanswered by DisplayServices here, so its
        // vendor number alone has to keep it with macOS), 9 an LG UltraFine, which macOS drives under LG's number.
        let screens: [CGDirectDisplayID: (builtIn: Bool, vendor: UInt32, displayServices: Bool)] =
            [1: (true, 0x610, true), 7: (false, 0x10AC, false), 8: (false, 0x610, false), 9: (false, 0x1E6D, true)]
        handler.canSetVolume = { settable }
        handler.canMute = { mutable }
        handler.displayUnderPointer = { pointer }
        handler.macOSSetsBrightness = { id in
            screens[id].map { MediaKeys.macOSSetsBrightness(builtIn: $0.builtIn, vendor: $0.vendor, displayServices: $0.displayServices) } ?? false
        }
        handler.onPress = { presses.append($0) }
        func pump() { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05)) }
        func send(_ key: MediaKeys.Key, down: Bool = true, repeating: Bool = false, flags: CGEventFlags = [], code: Int? = nil) -> Bool {
            let event = MediaKeys.event(MediaKeys.Event(code: code ?? key.rawValue, down: down, repeating: repeating), flags: flags)!
            return handler.handle(MediaKeys.systemDefined, event) != nil
        }
        // A whole press: down, a repeat, up. True when all three went on to macOS.
        func press(_ key: MediaKeys.Key, flags: CGEventFlags = []) -> [Bool] {
            presses = []
            let passed = [send(key, flags: flags), send(key, repeating: true, flags: flags), send(key, down: false, flags: flags)]
            pump()
            return passed
        }
        let none = [false, false, false], all = [true, true, true]

        for key in [MediaKeys.Key.volumeUp, .volumeDown, .mute] {
            check(press(key) == none && presses == [MediaKeys.Press(key: key, fine: false, display: nil)] + (key == .mute ? [] : [MediaKeys.Press(key: key, fine: false, display: nil)]),
                  "\(key) with a volume that can be set: down, repeat and up are taken, and step \(presses.count) time(s)")
        }
        settable = false
        check(press(.volumeUp) == all && press(.volumeDown) == all && press(.mute) == all && presses.isEmpty,
              "with a device whose volume can't be set (HDMI to a TV), all three volume keys go to macOS")
        settable = true
        mutable = false
        check(press(.mute) == all && press(.volumeUp) == none, "a device without mute: mute goes to macOS, the volume keys are still taken")
        mutable = true

        check(press(.brightnessUp) == none && presses.first == MediaKeys.Press(key: .brightnessUp, fine: false, display: 7),
              "brightness up with the pointer on an external screen macOS can't set (a Dell) is taken, for that screen")
        check(press(.brightnessDown) == none && presses.first?.display == 7, "and brightness down")
        for (screen, name) in [(CGDirectDisplayID(1), "the built-in screen"), (8, "an Apple Studio Display"), (9, "an LG UltraFine"),
                               (CGDirectDisplayID?.none, "no screen")] {
            pointer = screen
            check(press(.brightnessUp) == all && press(.brightnessDown) == all && presses.isEmpty,
                  "on \(name) both brightness keys go to macOS")
        }
        pointer = 7
        presses = []
        let held = [send(.brightnessDown), { pointer = 1; return send(.brightnessDown, repeating: true) }(), send(.brightnessDown, down: false)]
        pump()
        check(held == none && presses.count == 1, "a held brightness key moved onto the built-in screen keeps its repeats and key-up (\(presses.count) step)")
        pointer = 7

        let option = CGEventFlags.maskAlternate, shift = CGEventFlags.maskShift
        check(press(.volumeUp, flags: [option, shift]) == none && presses.first?.fine == true, "⌥⇧ volume up is taken as a quarter step")
        check(press(.brightnessDown, flags: [option, shift]) == none && presses.first?.fine == true, "⌥⇧ brightness down too")
        check(press(.volumeUp, flags: shift) == none && presses.first?.fine == false, "⇧ alone is a whole step")
        check(press(.volumeUp, flags: [.maskAlphaShift, .maskSecondaryFn]) == none, "Caps Lock or fn held doesn't matter")
        for (flags, name) in [(option, "⌥ alone (opens Sound settings)"), (CGEventFlags.maskCommand, "⌘"), (CGEventFlags.maskControl, "⌃"),
                              ([CGEventFlags.maskCommand, option, shift], "⌘⌥⇧")] {
            check(press(.volumeUp, flags: flags) == all && press(.brightnessUp, flags: flags) == all, "\(name) with a key: goes to macOS")
        }

        presses = []
        for (code, name) in [(16, "play"), (17, "next"), (19, "fast"), (21, "keyboard light up"), (0x7F, "unknown 0x7F")] {
            check([send(.volumeUp, code: code), send(.volumeUp, down: false, code: code)] == [true, true], "\(name) (code \(code)) goes on untouched")
        }
        check(send(.volumeUp, down: false) && send(.volumeUp, repeating: true), "a key-up or a repeat with no taken press before it goes on")
        _ = send(.volumeDown)
        handler.tapWasDisabled()
        check(send(.volumeDown, down: false), "after the tap was switched off for a moment, a taken key's key-up goes on")
        pump()
        let letter = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)!
        check(handler.handle(.keyDown, letter) === letter, "an ordinary key press passes through")

        // As the tap runs it: on a thread of its own.
        var fromThread: Bool?
        let done = DispatchSemaphore(value: 0)
        Thread {
            fromThread = handler.handle(MediaKeys.systemDefined, MediaKeys.event(MediaKeys.Event(code: 0, down: true, repeating: false))!) == nil
            _ = handler.handle(MediaKeys.systemDefined, MediaKeys.event(MediaKeys.Event(code: 0, down: false, repeating: false))!)
            done.signal()
        }.start()
        done.wait()
        presses = []
        pump()
        check(fromThread == true && presses.count == 1, "on the tap's own thread the key is read and taken, and the step runs on the main thread")

        check(handler.isActive, "on: the handler is active")
        handler.isEnabled = false
        check(!handler.isActive, "off: the tap leaves it out, so every key goes to macOS")
    }

    // MARK: Whose brightness macOS sets

    private static func screenChecks(_ check: Check, _ note: (String) -> Void) {
        check(MediaKeys.macOSSetsBrightness(builtIn: true, vendor: 0, displayServices: false), "a built-in screen is macOS's, whatever else it says")
        check(MediaKeys.macOSSetsBrightness(builtIn: false, vendor: 0x610, displayServices: false),
              "an external screen with Apple's vendor number (0x610) is macOS's even without DisplayServices")
        check(MediaKeys.macOSSetsBrightness(builtIn: false, vendor: 0x1E6D, displayServices: true), "one DisplayServices says it can set is macOS's")
        check(!MediaKeys.macOSSetsBrightness(builtIn: false, vendor: 0x10AC, displayServices: false), "any other external screen is RubberMAC's")

        let canChange = MediaKeys.displayServicesCanChange
        check(canChange != nil, "this macOS has DisplayServicesCanChangeBrightness")
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count = UInt32(0)
        CGGetOnlineDisplayList(16, &ids, &count)
        for id in ids.prefix(Int(count)) {
            let builtIn = CGDisplayIsBuiltin(id) != 0
            note("screen \(id): \(builtIn ? "built in" : "external"), vendor 0x\(String(CGDisplayVendorNumber(id), radix: 16)), "
                 + "DisplayServices can set it \((canChange?(id)).map { "\($0)" } ?? "n/a"), so its brightness keys are \(MediaKeys.macOSSetsBrightness(id) ? "macOS's" : "RubberMAC's")")
            if builtIn { check(MediaKeys.macOSSetsBrightness(id) && canChange?(id) == true, "this Mac's built-in screen (\(id)) reads as macOS's, DisplayServices agreeing") }
        }
        check(canChange?(0x7777) == false, "DisplayServices says no for a screen that isn't there")
    }

    // MARK: Steps

    private static func stepChecks(_ check: Check) {
        var volume: Float = 0, path: [Float] = []
        for _ in 0..<17 { volume = LevelSteps.volume(volume, up: true, fine: false); path.append(volume) }
        check(path.prefix(16).enumerated().allSatisfy { $0.element == Float($0.offset + 1) / 16 } && path.last == 1,
              "volume goes up in 16 steps of 1/16 and stops at full")
        check(LevelSteps.volume(0, up: false, fine: false) == 0, "and down stops at 0")
        check(LevelSteps.volume(0.30, up: true, fine: false) == 0.375 && LevelSteps.volume(0.30, up: false, fine: false) == 0.25,
              "a volume between steps (0.30) goes to the nearest step and on: 0.375 up, 0.25 down")
        check(LevelSteps.volume(0.5, up: true, fine: true) == 0.515625 && LevelSteps.volume(0.5, up: false, fine: true) == 0.484375,
              "⌥⇧ steps a quarter: 1/64")

        var percent = 100, percents: [Int] = []
        for _ in 0..<16 { percent = LevelSteps.brightness(percent, up: false, fine: false); percents.append(percent) }
        check(percents == [94, 88, 81, 75, 69, 63, 56, 50, 44, 38, 31, 25, 19, 13, 6, 0], "brightness down in 16 steps: \(percents)")
        var up = 0, ups = 0
        while up < 100 && ups < 70 { up = LevelSteps.brightness(up, up: true, fine: true); ups += 1 }
        check(ups == 64, "⌥⇧ brightness reaches full from 0 in 64 quarter steps (\(ups)), whole percents never stalling")
        check(LevelSteps.brightness(100, up: true, fine: false) == 100 && LevelSteps.brightness(0, up: false, fine: false) == 0, "brightness stops at 0 and 100")

        check(LevelSteps.apply(.volumeUp, fine: false, volume: 0.5, muted: true) == (0.5625, false)
              && LevelSteps.apply(.volumeDown, fine: false, volume: 0.5, muted: true) == (0.4375, false),
              "either volume key turns mute off and steps")
        check(LevelSteps.apply(.mute, fine: false, volume: 0.5, muted: false) == (0.5, true)
              && LevelSteps.apply(.mute, fine: false, volume: 0.5, muted: true) == (0.5, false), "mute switches mute and keeps the volume")

        let symbols = [(Float(0.5), true), (0, false), (0.25, false), (0.5, false), (0.9, false)].map { LevelSteps.volumeSymbol($0.0, muted: $0.1) }
        check(symbols == ["speaker.slash.fill", "speaker.slash.fill", "speaker.wave.1.fill", "speaker.wave.2.fill", "speaker.wave.3.fill"],
              "the speaker shows mute, then one, two or three waves: \(symbols.joined(separator: ", "))")
        let missing = (symbols + [LevelSteps.brightnessSymbol]).filter { NSImage(systemSymbolName: $0, accessibilityDescription: nil) == nil }
        check(missing.isEmpty, "every symbol is one this macOS has" + (missing.isEmpty ? "" : "; missing: \(missing)"))
    }

    // MARK: The window, off screen

    private static func windowChecks(_ check: Check, _ note: (String) -> Void) {
        let windows = LevelOverlayWindows()
        let panel = windows.panel(for: 1)
        check(windows.panel(for: 1) === panel && windows.panel(for: 2) !== panel, "one window per screen, the same one again for the same screen")
        check(!panel.canBecomeKey && !panel.canBecomeMain && panel.styleMask.contains(.nonactivatingPanel), "it never takes focus")
        check(panel.ignoresMouseEvents, "clicks go through it")
        check(!panel.hidesOnDeactivate, "it stays up while RubberMAC isn't the active app")
        check(panel.collectionBehavior.isSuperset(of: [.canJoinAllSpaces, .fullScreenAuxiliary]), "it shows on every Space, full-screen ones too")
        check(panel.level.rawValue > ScreenOverlay.brightnessLevel.rawValue, "it's above RubberMAC's software dimming (\(panel.level.rawValue) > \(ScreenOverlay.brightnessLevel.rawValue))")
        check(panel.content.material == .hudWindow && panel.content.state == .active, "a HUD material that stays vivid with RubberMAC in the background")
        check(!panel.isVisible, "and nothing was put on screen")

        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080), visible = CGRect(x: 0, y: 70, width: 1920, height: 985)
        let frame = LevelOverlayWindows.frame(screen: screen, visible: visible)
        check(frame.midX == screen.midX && frame.minY == 70 + 108 && frame.maxY < screen.height / 3,
              "on a 1920 × 1080 screen with the Dock at the bottom it's centred, a tenth up from the Dock: \(frame)")
        let second = CGRect(x: -2560, y: 200, width: 2560, height: 1440)
        let there = LevelOverlayWindows.frame(screen: second, visible: second)
        check(there.midX == second.midX && second.contains(there) && there.minY == second.minY + 144, "on a screen to the left, it's on that screen: \(there)")

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("level-overlay")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let view = LevelOverlayView(frame: NSRect(origin: .zero, size: LevelOverlayWindows.size))
            view.appearance = NSAppearance(named: appearance)
            for (level, expected) in [(0.0, 0), (6.4 / 16, 6), (1.0, 16)] {
                view.show(symbol: "speaker.wave.2.fill", level: level)
                let lit = litSegments(view.bar, dark: name == "dark")
                check(lit.count == expected && lit == Array(0..<expected), "\(name): level \(level) lights \(lit.count) of 16 segments")
            }
            view.show(symbol: LevelSteps.brightnessSymbol, level: 6.25 / 16)
            let quarter = sample(view.bar, segment: 6, at: 0.12, dark: name == "dark"), rest = sample(view.bar, segment: 6, at: 0.6, dark: name == "dark")
            check(quarter && !rest, "\(name): a quarter step lights a quarter of the next segment")
            check(view.icon.image != nil, "\(name): the symbol is drawn")
            view.show(symbol: "speaker.wave.2.fill", level: 0.5)
            if save(view, to: folder.appendingPathComponent("overlay-\(name).png")) { note("drew \(folder.path)/overlay-\(name).png") }
        }
    }

    // Segments whose middle is lit: the label colour at full strength rather than faint.
    private static func litSegments(_ bar: LevelBarView, dark: Bool) -> [Int] {
        (0..<LevelSteps.segments).filter { sample(bar, segment: $0, at: 0.5, dark: dark) }
    }

    private static func sample(_ bar: LevelBarView, segment: Int, at fraction: CGFloat, dark: Bool) -> Bool {
        guard let rep = bar.bitmapImageRepForCachingDisplay(in: bar.bounds) else { return false }
        bar.cacheDisplay(in: bar.bounds, to: rep)
        let rect = bar.segments[segment]
        let scale = CGFloat(rep.pixelsWide) / bar.bounds.width
        let x = Int((rect.minX + rect.width * fraction) * scale), y = Int((bar.bounds.height - rect.midY) * scale)
        guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return false }
        return color.alphaComponent > 0.6 && (dark ? color.brightnessComponent > 0.8 : color.brightnessComponent < 0.2)
    }

    private static func save(_ view: NSView, to url: URL) -> Bool {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.cacheDisplay(in: view.bounds, to: rep)
        let image = NSImage(size: view.bounds.size)
        image.lockFocus()
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            NSColor.windowBackgroundColor.setFill()
            view.bounds.fill()
        }
        rep.draw(in: view.bounds)
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        else { return false }
        return (try? png.write(to: url)) != nil
    }

    // MARK: Settings

    private static func settingsChecks(_ check: Check, _ note: (String) -> Void) {
        let stored = UserDefaults.standard.object(forKey: "levelOverlayEnabled") as? Bool
        note("levelOverlayEnabled stored: \(stored.map { "\($0)" } ?? "nothing (so the default)"), reads \(Settings.levelOverlayEnabled)")
        if stored == nil { check(Settings.levelOverlayEnabled, "with nothing stored it's on") }
        check(LevelOverlay().wantsAccess == Settings.levelOverlayEnabled, "it wants Accessibility exactly while it's on")

        let delegate = AppDelegate(lockWarning: LockWarning(timeoutOverride: nil))
        for permissions in [true, false] {
            var facts = SettingsFacts(version: "9.9.9", saverSummary: "", setupName: "")
            facts.permissions = PermissionCheck(accessibility: permissions, screenRecording: true, finder: .on, finderUsed: true)
            let page = delegate.settingsPages(facts).first { $0.id == "brightness" }
            let section = page?.sections.last
            let row = section?.rows.first
            var on: Bool?
            if case .toggle(let value)? = row?.control { on = value }
            check(section?.title == "Volume and Brightness Keys" && section?.rows.count == 1
                  && row?.title == "Show Volume and Brightness on the Screen You're Changing"
                  && row?.note == "Brightness keys work on external screens too",
                  "Accessibility \(permissions ? "on" : "off"): the Brightness page ends with Volume and Brightness Keys, its switch and note")
            check(on == Settings.levelOverlayEnabled && row?.action == #selector(AppDelegate.toggleLevelOverlay)
                  && (row?.target as AnyObject?)?.responds(to: #selector(AppDelegate.toggleLevelOverlay)) == true,
                  "the switch shows the setting and reaches toggleLevelOverlay (not pressed)")
            check(row?.closesPanel == !permissions, "without Accessibility it closes the panel for macOS's question")
        }
    }
}
