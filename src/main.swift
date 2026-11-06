import AppKit

// RubberMAC: one menu-bar app for the Big Clock screen saver, the pre-lock warning, brightness,
// Windows-style window snapping and keyboard habits, mouse speeds, window layouts and its own updates.
// --timeout N pretends the screen saver starts after N idle seconds (for testing the warning).

let logURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/ScreenTools.log")

func log(_ message: String) {
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
    print(line, terminator: "")
    fflush(stdout)
    if let handle = try? FileHandle(forWritingTo: logURL) {
        handle.seekToEndOfFile()
        handle.write(Data(line.utf8))
        try? handle.close()
    } else {
        try? line.write(to: logURL, atomically: true, encoding: .utf8)
    }
}

let args = CommandLine.arguments
let timeoutOverride = args.firstIndex(of: "--timeout").flatMap { i in i + 1 < args.count ? Double(args[i + 1]) : nil }

Settings.register()

let app = NSApplication.shared

// --selftest ddc|windows|switch|previews|previews-fullscreen|pad|padkeys|finder|finder-bar|tap|dock|dockmenu|dockmenu-ui|usage|camera|layouts|input|mouse|update|update-install|update-trust|permissions prints a diagnostic report and exits (run inside the
// signed app so Accessibility applies: open -n --stdout <file> "RubberMAC.app" --args --selftest windows).
if let i = args.firstIndex(of: "--selftest"), i + 1 < args.count {
    switch args[i + 1] {
    case "ddc": print(DDC.selfTestReport())
    case "windows": print(WindowSwitcher.selfTestReport())
    case "switch": print(WindowSwitcher.switchSelfTestReport())
    case "previews":
        let png = FileManager.default.temporaryDirectory.appendingPathComponent("switcher-preview.png")
        print(WindowThumbnails.selfTestReport(png: i + 2 < args.count ? URL(fileURLWithPath: args[i + 2]) : png))
    case "previews-fullscreen": print(WindowThumbnails.fullScreenSelfTestReport())
    case "pad": print(WritingAssistant.selfTestReport())
    case "finder": print(FinderPathPaste.selfTestReport())
    case "finder-bar": print(FinderAddressBar.selfTestReport())
    case "tap": print(EventTap.selfTestReport())
    case "dock": print(FullScreenDock.selfTestReport())
    case "dockmenu": print(DockWindowPicker.selfTestReport())
    case "dockmenu-helper": DockWindowPicker.runHelper(folder: args[i + 2])
    case "dockmenu-ui":
        let png = FileManager.default.temporaryDirectory.appendingPathComponent("dock-menu.png")
        print(DockWindowMenu.selfTestReport(png: i + 2 < args.count ? URL(fileURLWithPath: args[i + 2]) : png))
    case "usage": print(ProcessUsage.selfTestReport())
    case "padkeys": print(WritingPadKeys.selfTestReport())
    case "camera": print(WindowSnapper.cameraSelfTestReport())
    case "layouts": print(LayoutKeeper.selfTestReport())
    case "input": print(InputSources.selfTestReport())
    case "mouse": print(PointerSpeed.selfTestReport())
    case "permissions": print(PermissionRequest.selfTestReport())
    case "update": print(UpdateInstaller.selfTestReport(install: false))
    case "update-install": print(UpdateInstaller.selfTestReport(install: true))
    case "update-trust": print(UpdateInstaller.trustSelfTestReport(others: args[(i + 2)...].map { URL(fileURLWithPath: $0) }))
    default: print("unknown self-test: \(args[i + 1])")
    }
    exit(0)
}

app.setActivationPolicy(.accessory)
let delegate = AppDelegate(lockWarning: LockWarning(timeoutOverride: timeoutOverride))
app.delegate = delegate
app.run()
