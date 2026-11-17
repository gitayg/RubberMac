import AppKit

// --selftest resolution: the popup's titles, groups, native and current marks and dedupe, from this Mac's real mode
// list (read, never set) and from made-up ones; the countdown with a made-up clock and made-up screens; the question,
// drawn off-screen; and the settings rows. Changes no screen's mode, shows no window, changes no setting.
// --selftest resolution-live: see ScreenResolutionLiveSelfTest.swift.
extension ScreenResolution {
    typealias Check = (Bool, String) -> Void

    static func selfTestReport() -> String {
        var lines: [String] = []
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            if !ok { failures += 1 }
            lines.append("\(ok ? "ok  " : "FAIL") \(what)")
        }
        func note(_ text: String) { lines.append("     \(text)") }
        let domain = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName
        let stored = UserDefaults.standard.persistentDomain(forName: domain) as NSDictionary?
        let before = ScreenResolutionQuartz().displays().map { ($0, CGDisplayCopyDisplayMode($0).map(Mode.init)) }

        thisMac(check, note)
        madeUpLists(check)
        dedupeChecks(check)
        countdownChecks(check)
        featureChecks(check)
        questionChecks(check, note)
        settingsChecks(check, note)

        let after = ScreenResolutionQuartz().displays().map { ($0, CGDisplayCopyDisplayMode($0).map(Mode.init)) }
        check(before.map(\.0) == after.map(\.0) && zip(before, after).allSatisfy { $0.1 == $1.1 }, "no screen's mode changed")
        let now = UserDefaults.standard.persistentDomain(forName: domain) as NSDictionary?
        check(stored?.isEqual(now) ?? (now == nil), "no stored setting changed")
        return (lines + [failures == 0 ? "PASS" : "FAIL: \(failures) failed"]).joined(separator: "\n")
    }

    static func mode(_ id: Int32, _ pixelWidth: Int, _ pixelHeight: Int, _ width: Int, _ height: Int, _ refresh: Double,
                     usable: Bool = true, native: Bool = false) -> Mode {
        Mode(id: id, pixelWidth: pixelWidth, pixelHeight: pixelHeight, width: width, height: height, refresh: refresh, usable: usable, native: native)
    }

    // Groups apart with " / ", the current one in brackets.
    static func shown(_ groups: [[Entry]]) -> String {
        groups.map { $0.map { $0.current ? "[\($0.title)]" : $0.title }.joined(separator: " | ") }.joined(separator: " / ")
    }

    // MARK: This Mac

    private static func thisMac(_ check: Check, _ note: (String) -> Void) {
        let quartz = ScreenResolutionQuartz()
        for display in quartz.displays() {
            let name = NSScreen.screens.first { $0.displayID == display }?.localizedName ?? "display \(display)"
            let reading = reading(display)
            let groups = menu(reading.modes, current: reading.current)
            let entries = Array(groups.joined())
            let usable = reading.modes.filter(\.usable)
            note("\(name) (display \(display)\(CGDisplayIsBuiltin(display) != 0 ? ", built-in" : "")): macOS lists \(reading.modes.count) modes, "
                 + "\(usable.count) usable for the desktop; the popup has \(entries.count) in \(groups.count) groups:")
            for (index, group) in groups.enumerated() {
                if index > 0 { note("  ----") }
                for entry in group {
                    note("  \(entry.current ? "✓" : " ") \(entry.title)   (mode \(entry.mode.id))")
                }
            }
            check(!entries.isEmpty, "\(name): the popup lists its modes")
            check(Set(entries.map(\.title)).count == entries.count, "\(name): no two items read the same")
            check(entries.filter(\.current).count == 1 && entries.first { $0.current }?.mode == reading.current,
                  "\(name): the mode in use is the one ticked: \(entries.first { $0.current }?.title ?? "none")")
            check(entries.allSatisfy { $0.mode.usable || $0.current }, "\(name): every item is usable for the desktop (or the one in use)")
            // Told apart here by their numbers, not by the code under test.
            func key(_ mode: Mode) -> String { "\(mode.pixelWidth)x\(mode.pixelHeight) \(mode.width)x\(mode.height) \(Int((mode.refresh * 100).rounded()))" }
            let distinct = Set(usable.map(key))
            check(distinct.allSatisfy { wanted in entries.filter { key($0.mode) == wanted }.count == 1 },
                  "\(name): every usable mode is there, once (\(usable.count) usable, \(distinct.count) unlike → \(entries.count) items)")
            let natives = entries.filter(\.native)
            check(!natives.isEmpty && natives.allSatisfy { $0.title.hasSuffix("(native)") } && entries.filter { !$0.native }.allSatisfy { !$0.title.contains("native") },
                  "\(name): the screen's own resolution is marked native: \(natives.first.map { "\($0.mode.pixelWidth) × \($0.mode.pixelHeight)" } ?? "none")")
            let sizes = groups.compactMap(\.first).filter { !$0.title.hasPrefix("Looks like") }.map { $0.mode.pixelWidth * $0.mode.pixelHeight }
            check(zip(sizes, sizes.dropFirst()).allSatisfy { $0 > $1 }, "\(name): groups go from the most pixels sent to the fewest")
        }
    }

    // MARK: Made-up screens

    private static func madeUpLists(_ check: Check) {
        // A 27-inch 4K screen at one refresh rate, in its usual "looks like 2560 × 1440".
        let fourK = [
            mode(1, 3840, 2160, 3840, 2160, 60, native: true), mode(2, 3840, 2160, 1920, 1080, 60, native: true),
            mode(3, 5120, 2880, 2560, 1440, 60), mode(4, 4480, 2520, 2240, 1260, 60), mode(5, 3200, 1800, 1600, 900, 60),
            mode(6, 2560, 1440, 2560, 1440, 60), mode(7, 1920, 1080, 1920, 1080, 60), mode(8, 1920, 1080, 1920, 1080, 60, usable: false),
            mode(9, 1280, 720, 1280, 720, 60), mode(10, 640, 480, 640, 480, 60, usable: false),
        ]
        let fourKShown = shown(menu(fourK, current: fourK[2]))
        check(fourKShown == "3840 × 2160 (native) | 3840 × 2160, looks like 1920 × 1080 (native) / 3200 × 1800, looks like 1600 × 900 / "
              + "2560 × 1440 / 1920 × 1080 / 1280 × 720 / [Looks like 2560 × 1440, drawn at 5120 × 2880] | Looks like 2240 × 1260, drawn at 4480 × 2520",
              "4K screen: by pixels sent, native first, one rate so no Hz, and HiDPI drawn above 4K said as such, last: \(fourKShown)")

        // A TV over HDMI with film and PAL rates.
        let tv = [
            mode(1, 3840, 2160, 3840, 2160, 60, native: true), mode(2, 3840, 2160, 3840, 2160, 59.94005994, native: true),
            mode(3, 3840, 2160, 3840, 2160, 50, native: true), mode(4, 3840, 2160, 3840, 2160, 30, native: true),
            mode(5, 3840, 2160, 3840, 2160, 29.97002997, native: true), mode(6, 3840, 2160, 3840, 2160, 25, native: true),
            mode(7, 3840, 2160, 3840, 2160, 24, native: true), mode(8, 3840, 2160, 3840, 2160, 23.97602398, native: true),
            mode(9, 1920, 1080, 1920, 1080, 60), mode(10, 1920, 1080, 1920, 1080, 59.94005994), mode(11, 1920, 1080, 1920, 1080, 50),
            mode(12, 1920, 1080, 1920, 1080, 24), mode(13, 3840, 2160, 1920, 1080, 60, native: true), mode(14, 3840, 2160, 1920, 1080, 30, native: true),
            mode(15, 1280, 720, 1280, 720, 60), mode(16, 1280, 720, 1280, 720, 50), mode(17, 720, 576, 720, 576, 50, usable: false),
        ]
        let tvShown = shown(menu(tv, current: tv[8]))
        check(tvShown == "3840 × 2160, 60 Hz (native) | 3840 × 2160, 59.94 Hz (native) | 3840 × 2160, 50 Hz (native) | 3840 × 2160, 30 Hz (native) | "
              + "3840 × 2160, 29.97 Hz (native) | 3840 × 2160, 25 Hz (native) | 3840 × 2160, 24 Hz (native) | 3840 × 2160, 23.98 Hz (native) | "
              + "3840 × 2160, looks like 1920 × 1080, 60 Hz (native) | 3840 × 2160, looks like 1920 × 1080, 30 Hz (native) / "
              + "[1920 × 1080, 60 Hz] | 1920 × 1080, 59.94 Hz | 1920 × 1080, 50 Hz | 1920 × 1080, 24 Hz / 1280 × 720, 60 Hz | 1280 × 720, 50 Hz",
              "TV: each rate said, fastest first, 59.94 and 23.976 to the hundredth, the PAL-only 720 × 576 left out: \(tvShown)")

        // A 13-inch MacBook Air's built-in screen in its default "looks like 1280 × 832".
        let builtIn = [
            mode(1, 2560, 1664, 1280, 832, 60, native: true), mode(2, 2940, 1912, 1470, 956, 60), mode(3, 3420, 2224, 1710, 1112, 60),
            mode(4, 2048, 1332, 1024, 666, 60), mode(5, 2560, 1664, 2560, 1664, 60, native: true), mode(6, 1280, 832, 1280, 832, 60),
            mode(7, 1470, 956, 1470, 956, 60), mode(8, 1024, 666, 1024, 666, 60), mode(9, 800, 520, 800, 520, 60, usable: false),
        ]
        let builtInShown = shown(menu(builtIn, current: builtIn[0]))
        check(builtInShown == "2560 × 1664 (native) | [2560 × 1664, looks like 1280 × 832 (native)] / 2048 × 1332, looks like 1024 × 666 / "
              + "1470 × 956 / 1280 × 832 / 1024 × 666 / Looks like 1710 × 1112, drawn at 3420 × 2224 | Looks like 1470 × 956, drawn at 2940 × 1912",
              "built-in screen: its real 2560 × 1664 sent plain or HiDPI, and the larger-looking sizes drawn above it last: \(builtInShown)")

        // A screen that marks no mode native and gives no refresh rate, as some adapters do.
        let unmarked = [mode(1, 1920, 1080, 1920, 1080, 0), mode(2, 1680, 1050, 1680, 1050, 0), mode(3, 1920, 1080, 960, 540, 0),
                        mode(4, 3840, 2160, 1920, 1080, 0), mode(5, 1280, 720, 1280, 720, 0)]
        let unmarkedShown = shown(menu(unmarked, current: unmarked[0]))
        check(unmarkedShown == "3840 × 2160, looks like 1920 × 1080 / [1920 × 1080 (native)] | 1920 × 1080, looks like 960 × 540 (native) / "
              + "1680 × 1050 / 1280 × 720",
              "no native mark: the most pixels a plain mode sends is taken as native, and nothing is called drawn larger: \(unmarkedShown)")

        check(hertz(60) == "60 Hz" && hertz(59.94005994) == "59.94 Hz" && hertz(23.97602398) == "23.98 Hz" && hertz(47.952) == "47.95 Hz"
              && hertz(119.88) == "119.88 Hz" && hertz(29.5) == "29.5 Hz", "refresh rates: whole hertz plainly, others to the hundredth")
        check(title(of: tv[9], among: tv) == "1920 × 1080, 59.94 Hz" && title(of: fourK[2], among: fourK) == "Looks like 2560 × 1440, drawn at 5120 × 2880",
              "a mode's title for the question is its title in the popup")
    }

    private static func dedupeChecks(_ check: Check) {
        // As this Mac lists 1024 × 768 at 60 Hz twice, once not usable; here the unusable one comes first.
        let twice = [mode(114, 1024, 768, 1024, 768, 60, usable: false), mode(9, 1024, 768, 1024, 768, 60), mode(8, 1280, 960, 1280, 960, 60)]
        let entries = Array(menu(twice, current: twice[2]).joined())
        check(entries.map(\.mode.id) == [8, 9], "a mode listed twice, once unusable, is one item, the usable one (modes \(entries.map(\.mode.id)))")
        let alike = [mode(20, 1920, 1080, 1920, 1080, 60), mode(21, 1920, 1080, 1920, 1080, 60.0001), mode(22, 1280, 720, 1280, 720, 60)]
        let first = Array(menu(alike, current: alike[2]).joined()), inUse = Array(menu(alike, current: alike[1]).joined())
        check(first.map(\.mode.id) == [20, 22] && inUse.map(\.mode.id) == [21, 22] && inUse[0].current,
              "two usable look-alikes are one item: the first listed, or the one in use when it's one of them")
        let unusable = mode(30, 1600, 900, 1600, 900, 60, usable: false)
        let withUnusable = Array(menu(alike + [unusable], current: unusable).joined())
        check(withUnusable.contains { $0.mode == unusable && $0.current }, "a mode in use that macOS calls unusable is still listed, ticked")
        let stray = mode(40, 1366, 768, 1366, 768, 60)
        check(Array(menu(alike, current: stray).joined()).contains { $0.mode == stray && $0.current }, "and so is one in use that isn't in the list")
        check(menu([], current: nil).isEmpty, "a screen that lists nothing has an empty popup")
    }
}
