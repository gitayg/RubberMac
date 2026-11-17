import Foundation

// The app --selftest openonscreen-live opens files in: an ordinary app of its own, built from this source with swiftc,
// so the test acts only on windows it made. Each file holds "<kind> x y width height" in the Accessibility space and
// becomes a window there: "window", "panel", "sheet" on the last window without one, or a tab added to the first window
// ("tab") or the last ("tablast"). Windows don't become tabs on their own, whatever the Mac's tab setting. It quits once
// the test does.
enum OpenOnScreenScratch {
    static let bundleID = "app.rubbermac.openonscreen-scratch"
    static let name = "OpenOnScreen Scratch"

    static let source = #"""
    import AppKit

    final class Scratch: NSObject, NSApplicationDelegate {
        var windows: [NSWindow] = []

        func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }

        func applicationDidFinishLaunching(_ notification: Notification) {
            let args = CommandLine.arguments
            guard let i = args.firstIndex(of: "--parent"), i + 1 < args.count, let parent = Int32(args[i + 1]) else { return }
            Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in if kill(parent, 0) != 0 { exit(0) } }
        }

        func application(_ application: NSApplication, open urls: [URL]) {
            urls.forEach(open)
        }

        func open(_ url: URL) {
            let parts = ((try? String(contentsOf: url, encoding: .utf8)) ?? "").split(separator: " ").map(String.init)
            let numbers = parts.dropFirst().compactMap(Double.init)
            guard parts.count == 5, numbers.count == 4 else { return }
            let top = NSScreen.screens.first?.frame.height ?? 0
            let frame = NSRect(x: numbers[0], y: top - numbers[1] - numbers[3], width: numbers[2], height: numbers[3])
            let window: NSWindow
            if parts[0] == "panel" {
                let panel = NSPanel(contentRect: frame, styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
                panel.isFloatingPanel = true
                window = panel
            } else {
                window = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            }
            window.isReleasedWhenClosed = false
            window.setFrame(frame, display: false)
            let ordinary = windows.filter { !($0 is NSPanel) && $0.sheetParent == nil }
            if parts[0] == "sheet", let parent = ordinary.last(where: { $0.attachedSheet == nil }) {
                parent.beginSheet(window)
            } else if parts[0].hasPrefix("tab"), let parent = parts[0] == "tab" ? ordinary.first : ordinary.last {
                parent.addTabbedWindow(window, ordered: .above)
                window.makeKeyAndOrderFront(nil)
            } else {
                window.makeKeyAndOrderFront(nil)
            }
            windows.append(window)
        }
    }

    NSWindow.allowsAutomaticWindowTabbing = false
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let scratch = Scratch()
    app.delegate = scratch
    app.run()
    """#

    // Built once into the folder, and again only when the source changed. nil, with what went wrong, if it can't be.
    static func build(in folder: URL) -> (app: URL?, problem: String?) {
        let fm = FileManager.default
        let app = folder.appendingPathComponent("\(name).app")
        let contents = app.appendingPathComponent("Contents")
        let executable = contents.appendingPathComponent("MacOS/OpenOnScreenScratch")
        let copy = folder.appendingPathComponent("OpenOnScreenScratch.swift")
        if fm.fileExists(atPath: executable.path), (try? String(contentsOf: copy, encoding: .utf8)) == source { return (app, nil) }
        try? fm.removeItem(at: app)
        do {
            try fm.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
            try source.write(to: copy, atomically: true, encoding: .utf8)
        } catch {
            return (nil, "couldn't write to \(folder.path): \(error.localizedDescription)")
        }
        let info: NSDictionary = ["CFBundleExecutable": "OpenOnScreenScratch", "CFBundleIdentifier": bundleID, "CFBundleName": name,
                                  "CFBundlePackageType": "APPL", "CFBundleShortVersionString": "1.0", "NSHighResolutionCapable": true]
        info.write(to: contents.appendingPathComponent("Info.plist"), atomically: true)
        for (tool, arguments) in [("/usr/bin/xcrun", ["swiftc", "-o", executable.path, copy.path]),
                                  ("/usr/bin/codesign", ["--force", "--sign", "-", app.path])] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = arguments
            let output = Pipe()
            process.standardOutput = output
            process.standardError = output
            do { try process.run() } catch { return (nil, "couldn't run \(tool): \(error.localizedDescription)") }
            let said = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                try? fm.removeItem(at: copy)
                return (nil, "\((tool as NSString).lastPathComponent) failed (\(process.terminationStatus)): " + said.suffix(400))
            }
        }
        return (app, nil)
    }
}
