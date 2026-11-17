import AppKit

// --selftest fonttargets: each app's font change on a scratch copy of its settings, never the app's own: on sets the
// fonts and keeps the sizes, off puts back exactly what was there, a missing setting included; and the row of icons
// shows which are on and switches the one clicked. Leaves every real app's settings alone.
enum FontTargetsSelfTest {
    static func report() -> String {
        var lines: [String] = []
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            if !ok { failures += 1 }
            lines.append("\(ok ? "ok  " : "FAIL") \(what)")
        }
        // The bundled faces for this process only, so the test runs with the font off too.
        CTFontManagerRegisterFontURLs(BundledFont.faces() as CFArray, .process, false, nil)
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("rubbermac-fonttargets-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: scratch)
            for key in UserDefaults.standard.dictionaryRepresentation().keys where key.hasPrefix("fontTarget.selftest-") {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        func prefs(_ name: String) -> AppPrefs { AppPrefs(domain: scratch.appendingPathComponent("\(name).plist").path) }
        func ids(_ name: String) -> String { "selftest-\(name)-\(UUID().uuidString)" }
        let real = ["com.apple.TextEdit", "com.apple.mail"].map { AppPrefs.sandboxed($0).snapshot(MailFont.keys) }
            + [AppPrefs(domain: "com.apple.Terminal").snapshot(["Window Settings", "Default Window Settings", "Startup Window Settings"])]
        // Chrome rewrites its own Preferences while it runs, so only Firefox's, untouched since it last ran, can show this.
        func firefoxDates() -> [Date?] { FirefoxFont().profiles.map { (try? FileManager.default.attributesOfItem(atPath: $0.path))?[.modificationDate] as? Date } }
        let realFirefox = firefoxDates()

        do {
            // The preferences themselves: a value, a removal, and a restore that removes what was missing.
            let p = prefs("prefs")
            try p.set(["A": "one", "B": "two"])
            check(p.string("A") == "one" && p.string("B") == "two", "a scratch domain takes values")
            let before = p.snapshot(["A", "C"])
            try p.set(["A": "changed", "C": "added"])
            try p.restore(["A", "C"], from: before)
            check(p.string("A") == "one" && p.value("C") == nil && p.string("B") == "two",
                  "restoring puts a changed value back, removes one that wasn't there, and leaves other keys")

            // TextEdit, with no font set and with a font of the user's own.
            var textEdit = TextEditFont()
            textEdit.prefs = prefs("textedit")
            textEdit.id = ids("textedit")
            check(!textEdit.isOn, "TextEdit with no fonts set is off")
            try textEdit.turnOn()
            check(textEdit.isOn && textEdit.prefs.string("NSFont") == BundledFont.regular
                  && textEdit.prefs.string("NSFixedPitchFont") == BundledFont.monoRegular, "on: Next for rich text, Mono for plain text")
            try textEdit.turnOff()
            check(!textEdit.isOn && TextEditFont.keys.allSatisfy { textEdit.prefs.value($0) == nil }, "off: both settings gone again, as before")
            try textEdit.prefs.set(["NSFont": "Georgia", "NSFontSize": "15"])
            try textEdit.turnOn()
            check(textEdit.prefs.string("NSFontSize") == "15", "on keeps the size the user chose")
            try textEdit.turnOff()
            check(textEdit.prefs.string("NSFont") == "Georgia" && textEdit.prefs.value("NSFixedPitchFont") == nil,
                  "off puts back the user's own font and leaves the other unset")

            // Mail, whose message-list font is an archived font.
            var mail = MailFont()
            mail.prefs = prefs("mail")
            mail.id = ids("mail")
            guard let list = ArchivedFont.data(name: "Helvetica", size: 15) else { throw ArchivedFont.Missing() }
            try mail.prefs.set(["NSFont": "Helvetica", "NSFontSize": "15", "NSFixedPitchFont": "Menlo-Regular", "MessageListFont": list])
            check(!mail.isOn, "Mail with its own fonts is off")
            try mail.turnOn()
            let newList = mail.prefs.value("MessageListFont") as? Data
            check(mail.isOn && ArchivedFont.name(in: newList) == BundledFont.regular && ArchivedFont.size(in: newList) == 15,
                  "on: the message list in Next at its size, 15")
            try mail.turnOff()
            check(mail.prefs.string("NSFont") == "Helvetica" && mail.prefs.string("NSFixedPitchFont") == "Menlo-Regular"
                  && mail.prefs.value("MessageListFont") as? Data == list, "off: Mail's own fonts back, the archive byte for byte")

            // Terminal, closed: its profile is rewritten. A real profile's font (read only) stands in for Terminal's own.
            let realBasic = (AppPrefs(domain: "com.apple.Terminal").value("Window Settings") as? [String: Any])?["Basic"] as? [String: Any]
            let terminalFont = realBasic?["Font"] as? Data ?? ArchivedFont.data(name: "Menlo-Regular", size: 14)
            check(ArchivedFont.name(in: terminalFont) != nil && ArchivedFont.size(in: terminalFont) != nil,
                  "a Terminal profile's font reads without loading it: \(ArchivedFont.name(in: terminalFont) ?? "?") \(ArchivedFont.size(in: terminalFont).map { "\($0)" } ?? "?")")
            var terminal = TerminalFont()
            terminal.prefs = prefs("terminal")
            terminal.id = ids("terminal")
            terminal.isRunning = { false }
            try terminal.prefs.set(["Default Window Settings": "Basic", "Startup Window Settings": "Basic",
                                    "Window Settings": ["Basic": ["Font": terminalFont as Any, "rowCount": 24], "Pro": ["Font": terminalFont as Any]]])
            check(terminal.profiles == ["Basic"] && !terminal.isOn, "Terminal's default and startup profile, the same one, is off")
            try terminal.turnOn()
            let settings = terminal.prefs.value("Window Settings") as? [String: [String: Any]]
            check(terminal.isOn && ArchivedFont.size(in: terminal.fontData("Basic")) == ArchivedFont.size(in: terminalFont)
                  && settings?["Basic"]?["rowCount"] as? Int == 24 && settings?["Pro"]?["Font"] as? Data == terminalFont,
                  "on: the profile in Mono at its size, the rest of it and the other profiles untouched")
            try terminal.turnOff()
            check(terminal.fontData("Basic") == terminalFont && !terminal.isOn, "off: the profile's font back byte for byte")

            // Chrome: three profiles' Preferences, one with a font of the user's own; and the wait while it's open.
            let chromeRoot = scratch.appendingPathComponent("Chrome")
            var chromeFiles: [URL] = []
            for (name, prefs) in [("Default", ["browser": ["has_seen_welcome_page": true], "counter": 1.5] as [String: Any]),
                                  ("Profile 1", ["webkit": ["webprefs": ["fonts": ["standard": ["Zyyy": "Georgia", "Hans": "PingFang SC"]],
                                                                         "default_font_size": 18]]]),
                                  ("Profile 2", ["profile": ["name": "a"]])] {
                let folder = chromeRoot.appendingPathComponent(name)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let file = folder.appendingPathComponent("Preferences")
                try JSONSerialization.data(withJSONObject: prefs).write(to: file)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                chromeFiles.append(file)
            }
            try JSONSerialization.data(withJSONObject: ["profile": ["info_cache": ["Default": [:], "Profile 1": [:], "Profile 2": [:]]]])
                .write(to: chromeRoot.appendingPathComponent("Local State"))
            func chromeJSON() -> [NSDictionary] { chromeFiles.map { NSDictionary(dictionary: ChromeFont.read($0) ?? [:]) } }
            let chromeBefore = chromeJSON()
            var chromeOpen = true
            var chrome = ChromeFont()
            chrome.root = chromeRoot
            chrome.id = ids("chrome")
            chrome.isRunning = { chromeOpen }
            check(chrome.profiles.count == 3 && !chrome.isOn, "Chrome's three profiles, none set, is off")
            try chrome.turnOn()
            check(chrome.isOn && !chrome.isApplied && chromeJSON() == chromeBefore && chrome.whatChanges.hasSuffix("on once Chrome is quit"),
                  "clicked while Chrome is open: shows on, says it waits for Chrome to quit, and no file is touched")
            chromeOpen = false
            check(try chrome.applyPending() && chrome.isApplied && chrome.pending == nil, "Chrome quits: the change is made")
            let applied = chromeFiles.map { ChromeFont.fonts(in: ChromeFont.read($0) ?? [:]) }
            check(applied.allSatisfy { $0 == ["standard": BundledFont.family, "serif": BundledFont.family, "sansserif": BundledFont.family,
                                              "fixed": BundledFont.monoFamily] },
                  "every profile: Next for standard, serif and sans-serif, Mono for fixed-width")
            let second = ChromeFont.read(chromeFiles[1]) ?? [:]
            let secondFonts = ((second["webkit"] as? [String: Any])?["webprefs"] as? [String: Any])
            check((secondFonts?["fonts"] as? [String: [String: Any]])?["standard"]?["Hans"] as? String == "PingFang SC"
                  && secondFonts?["default_font_size"] as? Int == 18, "other scripts' fonts and the font size stay")
            check(chromeFiles.allSatisfy { (try? FileManager.default.attributesOfItem(atPath: $0.path))?[.posixPermissions] as? Int == 0o600 },
                  "each file keeps its permissions")
            chromeOpen = true
            try chrome.turnOff()
            check(!chrome.isOn && chrome.isApplied, "clicked off while open: shows off, files still on until Chrome quits")
            chromeOpen = false
            try chrome.applyPending()
            check(chromeJSON() == chromeBefore, "Chrome quits: every profile is back as it was, the user's Georgia included")
            chromeOpen = true
            try chrome.turnOn()
            try chrome.turnOff()
            check(chrome.pending == nil && !chrome.isOn, "on and off again while open cancels out, with nothing waiting")

            // Firefox: prefs.js lines, in two profiles from profiles.ini.
            let firefoxRoot = scratch.appendingPathComponent("Firefox")
            let prefsText = ["// Mozilla User Preferences", "", "user_pref(\"browser.startup.page\", 3);",
                             "user_pref(\"font.name.serif.x-western\", \"Georgia\");", ""].joined(separator: "\n")
            var firefoxFiles: [URL] = []
            for name in ["a.default-release", "b.default"] {
                let folder = firefoxRoot.appendingPathComponent("Profiles/\(name)")
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let file = folder.appendingPathComponent("prefs.js")
                try prefsText.write(to: file, atomically: true, encoding: .utf8)
                firefoxFiles.append(file)
            }
            try "[Profile1]\nName=default\nIsRelative=1\nPath=Profiles/b.default\nDefault=1\n\n[Profile0]\nName=default-release\nIsRelative=1\nPath=Profiles/a.default-release\n\n[General]\nVersion=2\n"
                .write(to: firefoxRoot.appendingPathComponent("profiles.ini"), atomically: true, encoding: .utf8)
            var firefox = FirefoxFont()
            firefox.root = firefoxRoot
            firefox.id = ids("firefox")
            firefox.isRunning = { false }
            check(firefox.profiles.count == 2 && !firefox.isOn, "Firefox's two profiles from profiles.ini, off")
            try firefox.turnOn()
            let text = (try? String(contentsOf: firefoxFiles[0], encoding: .utf8)) ?? ""
            check(firefox.isOn && text.contains("user_pref(\"font.name.sans-serif.x-western\", \"Atkinson Hyperlegible Next\");")
                  && text.contains("user_pref(\"font.name.monospace.x-western\", \"Atkinson Hyperlegible Mono\");")
                  && !text.contains("Georgia") && text.contains("browser.startup.page"),
                  "closed, on at once: Next for serif and sans-serif, Mono for monospace, other prefs kept")
            try firefox.turnOff()
            check(firefoxFiles.allSatisfy { (try? String(contentsOf: $0, encoding: .utf8)) == prefsText },
                  "off: each prefs.js back to the same text, the user's Georgia included")
        } catch {
            check(false, "the scratch settings: \(error)")
        }
        let realAfter = ["com.apple.TextEdit", "com.apple.mail"].map { AppPrefs.sandboxed($0).snapshot(MailFont.keys) }
            + [AppPrefs(domain: "com.apple.Terminal").snapshot(["Window Settings", "Default Window Settings", "Startup Window Settings"])]
        check(zip(real, realAfter).allSatisfy { NSDictionary(dictionary: $0).isEqual(to: $1) }, "TextEdit's, Mail's and Terminal's real settings are untouched")
        check(FirefoxFont().isRunning() || firefoxDates() == realFirefox, "no real Firefox profile was written (\(realFirefox.count) checked)")

        // RubberMAC's own Writing Pad.
        let padWas = Settings.padUsesAtkinson
        Settings.padUsesAtkinson = true
        let padOn = WritingPad.textFont
        Settings.padUsesAtkinson = false
        let padOff = WritingPad.textFont
        Settings.padUsesAtkinson = padWas
        check(padOn.fontName == BundledFont.regular && padOff.fontName != BundledFont.regular && padOn.pointSize == padOff.pointSize,
              "the Writing Pad writes in Next when its icon is on, in the system font when off, at the same size (\(padOff.fontName))")

        // The row of icons.
        let row = FontAppIcons()
        row.setFrameSize(NSSize(width: 460, height: FontAppIcons.height))
        var toggled: [String] = []
        row.onToggle = { toggled.append($0) }
        let icon = NSWorkspace.shared.icon(forFile: "/System/Applications/TextEdit.app")
        row.show([FontAppIcons.App(id: "a", name: "TextEdit", whatChanges: "new documents", isOn: true, icon: icon),
                  FontAppIcons.App(id: "b", name: "Mail", whatChanges: "messages", isOn: false, icon: icon)])
        row.layoutSubtreeIfNeeded()
        check(row.icons.count == 2 && row.icons[0].frame.maxX <= row.icons[1].frame.minX && row.icons[1].frame.maxX <= row.bounds.maxX,
              "one icon per app, left to right, inside the row")
        check(row.name.stringValue == "In TextEdit", "under the title: the apps using it, \"\(row.name.stringValue)\"")
        check(row.icons[0].accessibilityValue() as? Bool == true && row.icons[1].accessibilityValue() as? Bool == false
              && row.icons[0].accessibilityRole() == .checkBox, "VoiceOver reads each as a checkbox, on or off")
        row.icons[1].performClick(nil)
        check(toggled == ["b"], "clicking an icon switches that app")
        row.icons[1].onHover?("b")
        check(row.name.stringValue == "Mail: messages", "the pointer on an icon names the app and what changes")
        row.show([FontAppIcons.App(id: "a", name: "TextEdit", whatChanges: "new documents", isOn: false, icon: icon)])
        check(row.icons.count == 1 && row.name.stringValue == "Click an app to use it there", "with none on, it says what to do")

        lines.append(contentsOf: FontTargets.all.map { "on this Mac: \($0.appName) \($0.isInstalled ? ($0.isOn ? "on" : "off") : "not installed")" })
        return (lines + [failures == 0 ? "PASS" : "FAIL: \(failures) failed"]).joined(separator: "\n")
    }
}
