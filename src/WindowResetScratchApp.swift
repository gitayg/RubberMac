import AppKit

// The scratch app --selftest windowreset-live builds and works on, so the real quit, defaults, Trash and reopen happen
// to an app of its own: three windows, the first keeping its frame and its split view's divider under autosave names as
// an app's windows do. Its own bundle ID, so its preferences are its own. Told what to do by files in a folder beside it:
// "frames" (one window frame a line, in Accessibility points) places the windows as it opens, "refuse" makes it say no
// to quitting, as an app with unsaved work does.
enum WindowResetScratchApp {
    static let bundleID = "app.rubbermac.selftest.windowreset"
    static let name = "WindowReset Test"
    static let windowNames = ["Main", "Off", "Fine"]
    static let usualContent = NSRect(x: 200, y: 200, width: 520, height: 340)
    static let style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]

    // A window's size when it has nothing saved.
    static var usualSize: CGSize { NSWindow.frameRect(forContentRect: usualContent, styleMask: style).size }

    static func control(_ app: URL) -> URL {
        app.deletingLastPathComponent().appendingPathComponent("control")
    }

    // nil once built and signed, else what went wrong.
    static func build(_ app: URL) -> String? {
        let fm = FileManager.default
        let folder = app.deletingLastPathComponent()
        let contents = app.appendingPathComponent("Contents")
        try? fm.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        try? fm.createDirectory(at: control(app), withIntermediateDirectories: true)
        let source = folder.appendingPathComponent("main.swift")
        try? Self.source.write(to: source, atomically: true, encoding: .utf8)
        let info: NSDictionary = ["CFBundleIdentifier": bundleID, "CFBundleName": name, "CFBundleExecutable": "WindowResetTest",
                                  "CFBundlePackageType": "APPL", "CFBundleShortVersionString": "1.0", "NSPrincipalClass": "NSApplication",
                                  "NSHighResolutionCapable": true]
        info.write(to: contents.appendingPathComponent("Info.plist"), atomically: true)
        let compile = run("/usr/bin/swiftc", ["-Onone", "-module-cache-path", folder.appendingPathComponent("cache").path,
                                              "-o", contents.appendingPathComponent("MacOS/WindowResetTest").path, source.path])
        if compile != 0 { return "swiftc exited \(compile)" }
        let sign = run("/usr/bin/codesign", ["--force", "--sign", "-", app.path])
        return sign == 0 ? nil : "codesign exited \(sign)"
    }

    static func run(_ tool: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }

    private static let source = #"""
        import AppKit

        let control = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("control")

        // So the test can leave it off the screens, as a window gets left where a screen used to be.
        final class Window: NSWindow {
            override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
        }

        final class Delegate: NSObject, NSApplicationDelegate {
            var windows: [NSWindow] = []

            func applicationDidFinishLaunching(_ notification: Notification) {
                UserDefaults.standard.set("kept", forKey: "SelfTestKeep")
                UserDefaults.standard.set(true, forKey: "NSQuitAlwaysKeepsWindows")
                let top = NSScreen.screens[0].frame.maxY
                let given = ((try? String(contentsOf: control.appendingPathComponent("frames"), encoding: .utf8)) ?? "")
                    .split(separator: "\n").map { $0.split(separator: " ").compactMap { Double($0) } }.filter { $0.count == 4 }
                for (index, name) in ["Main", "Off", "Fine"].enumerated() {
                    let window = Window(contentRect: NSRect(x: 200, y: 200, width: 520, height: 340),
                                        styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false
                    window.title = "Scratch " + name
                    if index == 0 {
                        let split = NSSplitView(frame: window.contentView!.bounds)
                        split.isVertical = true
                        split.autoresizingMask = [.width, .height]
                        split.addArrangedSubview(NSView())
                        split.addArrangedSubview(NSView())
                        window.contentView = split
                        split.autosaveName = "Sidebar"
                        window.setFrameAutosaveName("Main")
                    }
                    if index < given.count {
                        let f = given[index]
                        window.setFrame(NSRect(x: f[0], y: top - f[1] - f[3], width: f[2], height: f[3]), display: false)
                    }
                    window.orderFront(nil)
                    windows.append(window)
                }
                if !given.isEmpty, let split = windows[0].contentView as? NSSplitView { split.setPosition(77, ofDividerAt: 0) }
                windows.forEach { $0.invalidateRestorableState() }
            }

            func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
                FileManager.default.fileExists(atPath: control.appendingPathComponent("refuse").path) ? .terminateCancel : .terminateNow
            }
        }

        let delegate = Delegate()
        NSApplication.shared.delegate = delegate
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.run()
        """#
}
