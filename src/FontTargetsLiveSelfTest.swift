import AppKit

// --selftest fonttargets-live: the real thing, on this Mac's own apps, the way the icons do it: each installed app is
// switched on, checked, switched off, and checked to be exactly as before. Chrome and Firefox only as far as they can
// be while they're open (the change waits, no file is touched); Terminal only if RubberMAC may already control it, so
// no permission is asked for. Run it only when you mean to: while it runs, a Terminal window can change font.
enum FontTargetsLiveSelfTest {
    static func report() -> String {
        var lines: [String] = []
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            if !ok { failures += 1 }
            lines.append("\(ok ? "ok  " : "FAIL") \(what)")
        }
        guard BundledFont.isAvailable else { return "skipped: turn the font on first (Writing page)" }

        func files(_ target: FontTarget) -> [URL] {
            switch target {
            case let t as TextEditFont: [URL(fileURLWithPath: t.prefs.domain)]
            case let t as MailFont: [URL(fileURLWithPath: t.prefs.domain)]
            case is TerminalFont: [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences/com.apple.Terminal.plist")]
            case let t as ChromeFont: t.profiles
            case let t as FirefoxFont: t.profiles
            default: []
            }
        }
        // What a file says, so before and after compare by content: a plist as its dictionary, anything else as text.
        func content(_ file: URL) -> NSObject? {
            guard let data = try? Data(contentsOf: file) else { return nil }
            if let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? NSDictionary { return plist }
            if let json = try? JSONSerialization.jsonObject(with: data) as? NSDictionary { return json }
            return String(data: data, encoding: .utf8) as NSString?
        }

        for target in FontTargets.installed where !(target is PadFont) {
            let name = target.appName
            if target.isOn { lines.append("skip \(name): already on, left as it is"); continue }
            if target is TerminalFont, AppScript.isRunning(target.bundleID) {
                let terminal = NSAppleEventDescriptor(bundleIdentifier: target.bundleID)
                let allowed = AEDeterminePermissionToAutomateTarget(terminal.aeDesc, AEEventClass(typeWildCard), AEEventID(typeWildCard), false)
                if allowed != noErr { lines.append("skip \(name): RubberMAC isn't allowed to control it yet (\(allowed))"); continue }
            }
            let before = files(target).map(content)
            do {
                try target.turnOn()
                let waits = (target as? QuitFirstFont).map { $0.isRunning() } ?? false
                if waits {
                    check(target.isOn && files(target).map(content) == before, "\(name) is open: on shows, waiting, and no file is touched")
                } else {
                    check(target.isOn, "\(name) on, read back from its own settings")
                }
                try target.turnOff()
                check(!target.isOn, "\(name) off again")
                let after = files(target).map(content)
                check(after == before, "\(name)'s settings are exactly as before (\(before.count) file(s))")
            } catch {
                check(false, "\(name): \(error)")
                try? target.turnOff()
            }
        }
        return (lines + [failures == 0 ? "PASS" : "FAIL: \(failures) failed"]).joined(separator: "\n")
    }
}
