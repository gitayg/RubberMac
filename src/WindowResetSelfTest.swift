import AppKit

// --selftest windowreset: when a window counts as lost and where it goes back to, on made-up screens; which keys are
// saved window sizes; the list of apps, made from a scratch folder; the forget flow with stand-ins for quitting,
// defaults, the Trash and reopening, and defaults itself on a scratch file; the settings rows, the list and the
// question. Moves no window, touches no app, and leaves every stored setting as it was.
enum WindowResetSelfTest {
    typealias Check = (Bool, String) -> Void

    static func report() -> String {
        var lines: [String] = []
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            if !ok { failures += 1 }
            lines.append("\(ok ? "ok  " : "FAIL") \(what)")
        }

        NSApp.setActivationPolicy(.accessory)
        let domain = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName
        // Less the focus order, which the running RubberMAC writes whenever a window comes forward.
        func settings() -> NSDictionary? {
            UserDefaults.standard.persistentDomain(forName: domain).map { $0.filter { $0.key != "focusHistory" } as NSDictionary }
        }
        let stored = settings()
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("windowreset-selftest-\(UUID().uuidString.prefix(8))")

        geometryChecks(check)
        keyChecks(check)
        scanChecks(scratch, check)
        WindowResetFlowSelfTest.forgetChecks(check)
        WindowResetFlowSelfTest.defaultsChecks(scratch, check)
        WindowResetFlowSelfTest.settingsChecks(check)
        try? FileManager.default.removeItem(at: scratch)

        let after = settings()
        check(stored?.isEqual(after) ?? (after == nil), "no stored setting changed")
        return (lines + [failures == 0 ? "PASS" : "FAIL: \(failures) failed"]).joined(separator: "\n")
    }

    // MARK: Lost windows

    private static func geometryChecks(_ check: Check) {
        let main = ScreenArea(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080), visible: CGRect(x: 0, y: 25, width: 1920, height: 1055))
        func lost(_ window: CGRect, _ screens: [ScreenArea] = [main]) -> WindowResetGeometry.Problem? {
            WindowResetGeometry.problem(window, screens: screens)
        }
        func fixed(_ window: CGRect, _ screens: [ScreenArea] = [main]) -> CGRect? {
            WindowResetGeometry.fixed(window, screens: screens)
        }
        func text(_ rect: CGRect?) -> String {
            rect.map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))×\(Int($0.height))" } ?? "untouched"
        }
        func expect(_ window: CGRect, _ problem: WindowResetGeometry.Problem?, _ goes: CGRect?, _ what: String,
                    _ screens: [ScreenArea] = [main]) {
            let got = fixed(window, screens)
            check(lost(window, screens) == problem && got == goes, "\(what): \(text(got))")
        }

        // One screen, the menu bar 25 points.
        expect(CGRect(x: 300, y: 300, width: 800, height: 600), nil, nil, "a window well on the screen is left alone")
        expect(main.visible, nil, nil, "a maximized window is left alone")
        expect(CGRect(x: 0, y: 25, width: 1921, height: 1056), nil, nil, "one a point over the screen (rounding) is left alone")
        expect(CGRect(x: 1500, y: 300, width: 800, height: 600), nil, nil, "one half off the right edge, its title bar in reach, is left alone")
        expect(CGRect(x: 1700, y: 300, width: 800, height: 600), .offScreen, CGRect(x: 1120, y: 300, width: 800, height: 600),
               "under a third showing: back against the right edge, the same size")
        expect(CGRect(x: -770, y: 300, width: 800, height: 600), .offScreen, CGRect(x: 0, y: 300, width: 800, height: 600),
               "a sliver at the left edge: back against it")
        expect(CGRect(x: 5000, y: 300, width: 800, height: 600), .offScreen, CGRect(x: 1120, y: 300, width: 800, height: 600),
               "on no screen at all (where a screen used to be): onto the main screen")
        expect(CGRect(x: 300, y: 0, width: 800, height: 600), .offScreen, CGRect(x: 300, y: 25, width: 800, height: 600),
               "its title bar under the menu bar: moved down below it")
        expect(CGRect(x: 300, y: -300, width: 800, height: 900), .offScreen, CGRect(x: 300, y: 25, width: 800, height: 900),
               "most of it showing but its title bar above the screen: brought down")
        expect(CGRect(x: 0, y: 25, width: 2400, height: 1300), .tooBig, main.visible, "bigger than the screen: shrunk to fit it")
        expect(CGRect(x: -200, y: 100, width: 2400, height: 1300), .tooBig, main.visible, "bigger and off-centre: shrunk and moved onto it")
        expect(CGRect(x: 300, y: 25, width: 800, height: 1200), .tooBig, CGRect(x: 300, y: 25, width: 800, height: 1055),
               "only too tall: shrunk in height, the width kept")
        let docked = ScreenArea(frame: main.frame, visible: CGRect(x: 0, y: 25, width: 1920, height: 985))
        expect(CGRect(x: 300, y: 1020, width: 800, height: 600), .offScreen, CGRect(x: 300, y: 410, width: 800, height: 600),
               "its title bar behind the Dock: brought up above it", [docked])
        check(fixed(CGRect(x: 5000, y: 300, width: 800, height: 600), []) == nil, "no screens at all (every display asleep): nothing to do")

        // Two screens: a laptop with a notch on the left (main), a big screen to its right standing higher.
        let laptop = ScreenArea(frame: CGRect(x: 0, y: 0, width: 1440, height: 900), visible: CGRect(x: 0, y: 38, width: 1440, height: 862))
        let big = ScreenArea(frame: CGRect(x: 1440, y: -540, width: 3440, height: 1440), visible: CGRect(x: 1440, y: -515, width: 3440, height: 1415))
        let two = [laptop, big]
        expect(CGRect(x: 4700, y: 100, width: 800, height: 600), .offScreen, CGRect(x: 4080, y: 100, width: 800, height: 600),
               "off the big screen's right edge: back onto the big screen, not the main one", two)
        expect(CGRect(x: 1040, y: 100, width: 800, height: 600), nil, nil, "a window across both screens is left alone", two)
        expect(CGRect(x: 1240, y: 500, width: 400, height: 800), nil, nil,
               "one across both with a quarter on each and the rest below them: what shows on both counts, left alone", two)
        expect(CGRect(x: 1500, y: -400, width: 2400, height: 1300), nil, nil, "bigger than the laptop but on the big screen: left alone", two)
        expect(CGRect(x: 0, y: 38, width: 2000, height: 1000), .tooBig, laptop.visible,
               "too big for the laptop and mostly on it: shrunk to the laptop's screen", two)
        expect(CGRect(x: -3000, y: -3000, width: 800, height: 600), .offScreen, CGRect(x: 0, y: 38, width: 800, height: 600),
               "far off both: onto the main screen", two)
        expect(CGRect(x: 0, y: 1200, width: 800, height: 600), .offScreen, CGRect(x: 0, y: 300, width: 800, height: 600),
               "below both: up onto the main screen", two)

        // A camera in front of the screen (the spot marked on this Mac's TV): a window put back keeps clear of it.
        let camera = ScreenArea(frame: main.frame, visible: CGRect(x: 0, y: 30, width: 1920, height: 1050),
                                blocked: CGRect(x: 749, y: 709, width: 219, height: 371))
        expect(CGRect(x: 0, y: 30, width: 2400, height: 1300), .tooBig, CGRect(x: 0, y: 30, width: 1920, height: 679),
               "with the camera, too big: shrunk to the part clear of the camera", [camera])
        expect(CGRect(x: 1700, y: 100, width: 800, height: 600), .offScreen, CGRect(x: 1120, y: 100, width: 800, height: 600),
               "with the camera, off the edge: back, the same size, clear of the camera", [camera])
        expect(CGRect(x: 700, y: 600, width: 400, height: 400), nil, nil, "with the camera, a window in front of it is still left alone", [camera])
        expect(camera.visible, nil, nil, "with the camera, one maximized over the whole screen (⌘↑ twice) is left alone", [camera])
    }

    // MARK: Saved window sizes

    private static func keyChecks(_ check: Check) {
        let frames = ["NSWindow Frame iCal", "NSWindow Frame Main Window", "NSSplitView Subview Frames CalendarSplitView",
                      "NSWindow Frame NSNavPanelAutosaveName"]
        let others = ["NSWindow Frame", "NSWindowFrame iCal", "nswindow frame iCal", "NSSplitView Subview Frames", "NSToolbar Configuration Main",
                      "NSTableView Columns v2 Events", "My NSWindow Frame iCal", "NSNavLastRootDirectory", "NSQuitAlwaysKeepsWindows", "SelfTestKeep"]
        let wrong = frames.filter { !WindowResetSavedFrames.isFrameKey($0) } + others.filter(WindowResetSavedFrames.isFrameKey)
        check(wrong.isEmpty, "only NSWindow Frame … and NSSplitView Subview Frames … keys are saved window sizes (\(frames.count) are, "
              + "\(others.count) aren't)" + (wrong.isEmpty ? "" : "; wrong: " + wrong.joined(separator: " | ")))
    }

    private static func scanChecks(_ scratch: URL, _ check: Check) {
        let fm = FileManager.default
        let library = scratch.appendingPathComponent("Library")
        let preferences = library.appendingPathComponent("Preferences")
        let containers = library.appendingPathComponent("Containers")
        let states = library.appendingPathComponent("Saved Application State")
        func write(_ object: Any, _ url: URL) {
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? PropertyListSerialization.data(fromPropertyList: object, format: .binary, options: 0).write(to: url)
        }
        func folder(_ url: URL) { try? fm.createDirectory(at: url, withIntermediateDirectories: true) }
        let frame = "100 200 800 600 0 0 1920 1055 "
        write(["NSWindow Frame Main": frame, "NSSplitView Subview Frames Side": ["0 0 200 600 NO NO"], "Other": 1],
              preferences.appendingPathComponent("com.example.alpha.plist"))
        write(["NSToolbar Configuration Main": ["a": 1], "Other": 1], preferences.appendingPathComponent("com.example.beta.plist"))
        write(["NSWindow Frame Main": frame], preferences.appendingPathComponent("com.example.ghost.plist"))
        write(["NSWindow Frame Zed": frame], preferences.appendingPathComponent("com.example.zulu.plist"))
        write(["NSWindow Frame Main"], preferences.appendingPathComponent("com.example.list.plist"))
        try? Data("NSWindow Frame Main = nonsense".utf8).write(to: preferences.appendingPathComponent("com.example.broken.plist"))
        try? Data("NSWindow Frame Main".utf8).write(to: preferences.appendingPathComponent("com.example.notes.txt"))
        write(["NSWindow Frame Main": frame], preferences.appendingPathComponent("ByHost/com.example.byhost.0000.plist"))
        let boxed = containers.appendingPathComponent("com.example.sandboxed/Data/Library/Preferences/com.example.sandboxed")
        write(["NSWindow Frame Box": frame, "Keep": true], boxed.appendingPathExtension("plist"))
        folder(containers.appendingPathComponent("com.example.emptybox/Data/Library"))
        for id in ["com.example.echo", "com.example.zulu", "com.example.ghost"] { folder(states.appendingPathComponent("\(id).savedState")) }
        try? Data().write(to: states.appendingPathComponent("stray.txt"))
        // Files the list must not open, locked so that opening one would show as refused: an Apple app's (macOS may ask
        // the user about it), in its preferences and its container, and the file of a domain that's no app.
        let appleBox = containers.appendingPathComponent("com.apple.example/Data/Library/Preferences/com.apple.example.plist")
        write(["NSWindow Frame Main": frame], preferences.appendingPathComponent("com.apple.example.plist"))
        write(["NSWindow Frame Main": frame], appleBox)
        let unopened = [preferences.appendingPathComponent("com.apple.example.plist"), appleBox, preferences.appendingPathComponent("com.example.ghost.plist")]
        for file in unopened { try? fm.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path) }
        defer { for file in unopened { try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path) } }

        let names = ["com.example.alpha": "Alpha", "com.example.beta": "Beta", "com.example.zulu": "Zulu", "com.example.echo": "Echo",
                     "com.example.sandboxed": "Sandboxed", "com.example.emptybox": "Empty Box", "com.example.list": "List",
                     "com.example.broken": "Broken", "com.example.byhost": "By Host", "com.apple.example": "Apple Example"]
        func resolve(_ id: String) -> (name: String, url: URL)? {
            names[id].map { ($0, URL(fileURLWithPath: "/Applications/\($0).app")) }
        }
        let places = WindowResetSavedFrames.Places(preferences: preferences, savedState: states, containers: nil)
        let closed = WindowResetSavedFrames.scan(places, resolve: resolve)
        func app(_ scan: WindowResetSavedFrames.Scan, _ name: String) -> WindowResetSavedFrames.App? { scan.apps.first { $0.name == name } }
        check(closed.apps.map(\.name) == ["Alpha", "Apple Example", "Echo", "Zulu"] && !closed.refused,
              "listed from the scratch folder, by name: \(closed.apps.map(\.name).joined(separator: ", ")) (no other keys, no app, "
              + "not a dictionary, not a plist, ByHost and the sandboxed one while containers aren't read: left out)")
        check(app(closed, "Apple Example").map { $0.unread && $0.keys.isEmpty } == true && !closed.refused
              && closed.apps.filter(\.unread).map(\.name) == ["Apple Example"],
              "an Apple app is listed without its file being opened, and a domain with no app isn't opened either (no locked file was)")
        check(app(closed, "Alpha")?.keys == ["NSSplitView Subview Frames Side", "NSWindow Frame Main"]
              && app(closed, "Alpha")?.hasSavedState == false, "an app's saved window sizes are listed, and only those")
        check(app(closed, "Alpha")?.savedState == states.appendingPathComponent("com.example.alpha.savedState"),
              "and where its saved windows would be, there or not")
        check(app(closed, "Zulu")?.keys == ["NSWindow Frame Zed"] && app(closed, "Zulu")?.hasSavedState == true,
              "sizes and saved windows of one app make one entry")
        check(app(closed, "Echo")?.keys == [] && app(closed, "Echo")?.hasSavedState == true, "saved windows alone are enough to be listed")

        var open = places
        open.containers = containers
        let all = WindowResetSavedFrames.scan(open, resolve: resolve)
        let sandboxed = app(all, "Sandboxed")
        check(all.apps.map(\.name) == ["Alpha", "Apple Example", "Echo", "Sandboxed", "Zulu"] && sandboxed?.keys == [] && sandboxed?.containerKeys == ["NSWindow Frame Box"]
              && sandboxed?.container == boxed, "with containers read, a sandboxed app is listed with its container's domain and keys: "
              + "\(all.apps.map(\.name).joined(separator: ", ")); \(sandboxed?.container.map { "…" + $0.path.dropFirst(library.path.count) } ?? "no domain") \(sandboxed?.containerKeys ?? [])")
        check(!all.refused && app(all, "Apple Example")?.container == appleBox.deletingPathExtension(),
              "an Apple app's container is noted by its file's name, still unopened")
        let locked = boxed.appendingPathExtension("plist")
        try? fm.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        let refused = WindowResetSavedFrames.scan(open, resolve: resolve)
        try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked.path)
        check(refused.refused && app(refused, "Sandboxed") == nil, "a container that can't be read is left out and noted as refused")

        // Which apps are offered: by where they're installed and what their Info.plist says.
        let home = fm.homeDirectoryForCurrentUser.path
        let locations: [(String, Bool)] = [
            ("/Applications/Xcode.app", true), ("/Applications/Utilities/Some Tool.app", true), ("/System/Applications/Calendar.app", true),
            ("/System/Applications/Utilities/Terminal.app", true), ("/System/Library/CoreServices/Applications/Keychain Access.app", true),
            (home + "/Applications/Chrome Apps.localized/Docs.app", true),
            ("/System/Library/CoreServices/Finder.app", false), ("/System/Library/CoreServices/loginwindow.app", false),
            ("/System/Library/PrivateFrameworks/UserActivity.framework/Agents/UASharedPasteboardProgressUI.app", false),
            (home + "/Downloads/Unzipped.app", false), (home + "/Documents/Projects/Built.app", false), ("/Volumes/Stick/Carried.app", false),
            (scratch.path + "/Apps/Plain.app", false),
        ]
        let misplaced = locations.filter { WindowResetSavedFrames.isInstalled(URL(fileURLWithPath: $0.0)) != $0.1 }.map(\.0)
        check(misplaced.isEmpty, "offered only from where apps are installed (/Applications, ~/Applications, /System/Applications, "
              + "CoreServices/Applications): not Finder, the login window, macOS agents, or apps in Downloads, Documents or on a stick"
              + (misplaced.isEmpty ? "" : "; wrong: " + misplaced.joined(separator: ", ")))
        func bundle(_ name: String, _ info: [String: Any]) -> URL {
            let url = scratch.appendingPathComponent("Apps/\(name).app")
            write(info, url.appendingPathComponent("Contents/Info.plist"))
            return url
        }
        check(!WindowResetSavedFrames.isBackgroundOnly(bundle("Plain", ["CFBundleName": "Plain"]))
              && WindowResetSavedFrames.isBackgroundOnly(bundle("Background", ["LSBackgroundOnly": true]))
              && WindowResetSavedFrames.isBackgroundOnly(bundle("Background Text", ["LSBackgroundOnly": "1"]))
              && !WindowResetSavedFrames.isOffered(URL(fileURLWithPath: "/Applications/RubberMAC.app"), bundleID: Bundle.main.bundleIdentifier ?? "")
              && WindowResetSavedFrames.isOffered(URL(fileURLWithPath: "/System/Applications/Calendar.app"), bundleID: "com.apple.iCal"),
              "nor background-only apps (said as a flag or as text), nor RubberMAC itself; Calendar is")
        let calendar = WindowResetSavedFrames.installedApp("com.apple.iCal")
        check(calendar?.name == "Calendar" && calendar?.url.path == "/System/Applications/Calendar.app"
              && WindowResetSavedFrames.installedApp("com.apple.finder") == nil
              && WindowResetSavedFrames.installedApp("com.apple.loginwindow") == nil
              && WindowResetSavedFrames.installedApp("com.example.no-such-app") == nil,
              "through Launch Services: com.apple.iCal is Calendar; Finder, the login window and a domain no app has aren't offered")
    }
}
