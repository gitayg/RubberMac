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

// --selftest ddc|windows|switch|previews|previews-fullscreen|pad|padkeys|finder|finder-bar|finder-trash|tap|dock|dockmenu|dockmenu-ui|usage|camera|layouts|input|mouse|update|update-install|update-trust|permissions|eyecamera|eyepreview|settings|settings-live prints a diagnostic report and exits (run inside the
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
    case "eyecamera": print(EyeCamera.selfTestReport())
    case "eyepreview": print(EyePreview.selfTestReport())
    case "virtualcam": print(VirtualCameraSink.selfTestReport())
    case "screenlock": print(ScreenLock.selfTestReport())
    case "fonts": print(BundledFont.selfTestReport())
    case "fonttargets": print(FontTargetsSelfTest.report())
    case "fonttargets-live": print(FontTargetsLiveSelfTest.report())
    case "spotlightkeys": print(SpotlightKeys.selfTestReport())
    case "desktopkeys": print(DesktopKeys.selfTestReport())
    case "desktopkeys-live": print(DesktopKeys.liveSelfTestReport())
    case "spotlightkeys-live": print(SpotlightKeys.liveSelfTestReport())
    case "spotlightfilter": print(SpotlightFilter.selfTestReport())
    case "spotlightfilter-live":
        // Under the real run loop, so Spotlight's Accessibility notifications arrive.
        app.setActivationPolicy(.accessory)
        RunLoop.main.perform {
            print(SpotlightFilter.liveSelfTestReport())
            exit(0)
        }
        app.run()
    case "spotlightfilter-typing":
        // Under the real run loop, so Spotlight's Accessibility notifications arrive.
        app.setActivationPolicy(.accessory)
        RunLoop.main.perform {
            print(SpotlightFilterProbe.typingReport(external: i + 2 < args.count && args[i + 2] == "external"))
            exit(0)
        }
        app.run()
    case "spotlightfilter-direct":
        // Under the real run loop, so Spotlight's Accessibility notifications arrive.
        app.setActivationPolicy(.accessory)
        RunLoop.main.perform {
            print(SpotlightFilterDirect.report())
            exit(0)
        }
        app.run()
    case "spotlightfilter-host":
        // Under the real run loop, so Spotlight's Accessibility notifications arrive.
        app.setActivationPolicy(.accessory)
        RunLoop.main.perform {
            print(SpotlightFilterHost.run(seconds: i + 2 < args.count ? Double(args[i + 2]) ?? 90 : 90, stopFile: i + 3 < args.count ? args[i + 3] : nil))
            exit(0)
        }
        app.run()
    case "spotlightfilter-probe":
        // Under the real run loop, so Spotlight's Accessibility notifications arrive.
        app.setActivationPolicy(.accessory)
        RunLoop.main.perform {
            print(SpotlightFilterProbe.report())
            exit(0)
        }
        app.run()
    case "startmenu": print(StartMenu.selfTestReport())
    case "startmenu-live": print(StartMenu.liveSelfTestReport())
    case "overlay": print(LevelOverlay.selfTestReport())
    case "overlay-live": print(LevelOverlay.liveSelfTestReport())
    case "dimmer": print(BackgroundDimmer.selfTestReport())
    case "dimmer-live": print(BackgroundDimmer.liveSelfTestReport())
    case "inputperapp": print(InputPerApp.selfTestReport())
    case "inputperapp-live": print(InputPerApp.liveSelfTestReport())
    case "dockscreen": print(DockScreen.selfTestReport())
    case "dockscreen-live": print(DockScreen.liveSelfTestReport())
    case "requests": print(FeatureRequest.selfTestReport())
    case "wheelstyle": print(WheelStyle.selfTestReport())
    case "wheelzoom-probe": print(WheelStyle.zoomProbeReport())
    case "wheelzoom-live": print(WheelStyle.zoomLiveSelfTestReport())
    case "windowreset": print(WindowReset.selfTestReport())
    case "windowreset-live": print(WindowReset.liveSelfTestReport())
    case "openonscreen": print(OpenOnScreen.selfTestReport())
    case "openonscreen-live": print(OpenOnScreen.liveSelfTestReport())
    case "resolution": print(ScreenResolution.selfTestReport())
    case "resolution-live": print(ScreenResolution.liveSelfTestReport())
    case "secureinput": print(SecureInput.selfTestReport())
    case "secureinput-live": print(SecureInput.liveSelfTestReport())
    case "eyelive":
        // Under the real run loop: EyeCamera's timer and its first-frame callback run on the main thread.
        app.setActivationPolicy(.accessory)
        RunLoop.main.perform {
            print(EyeCamera.liveSelfTestReport())
            exit(0)
        }
        app.run()
    case "eyepipeline":
        guard i + 2 < args.count else { print("usage: --selftest eyepipeline <photo.png> [folder]"); break }
        print(EyeCamera.pipelineSelfTestReport(photo: URL(fileURLWithPath: args[i + 2]),
                                               folder: i + 3 < args.count ? URL(fileURLWithPath: args[i + 3]) : nil))
    case "irisrecolor": print(IrisRecolor.selfTestReport())
    case "eyetracker": print(EyeTracker.selfTestReport())
    case "finder": print(FinderPathPaste.selfTestReport())
    case "finder-bar": print(FinderAddressBar.selfTestReport())
    case "finder-trash": print(FinderTrashKey.selfTestReport())
    case "tap": print(EventTap.selfTestReport())
    case "dock": print(FullScreenDock.selfTestReport())
    case "dockmenu": print(DockWindowPicker.selfTestReport())
    case "dockmenu-helper": DockWindowPicker.runHelper(folder: args[i + 2])
    case "dockmenu-ui":
        let png = FileManager.default.temporaryDirectory.appendingPathComponent("dock-menu.png")
        print(DockWindowMenu.selfTestReport(png: i + 2 < args.count ? URL(fileURLWithPath: args[i + 2]) : png))
    case "usage": print(ProcessUsage.selfTestReport())
    case "padkeys": print(WritingPadKeys.selfTestReport())
    case "snap": print(SnapGeometry.selfTestReport())
    case "camera": print(WindowSnapper.cameraSelfTestReport())
    case "layouts": print(LayoutKeeper.selfTestReport())
    case "input": print(InputSources.selfTestReport())
    case "mouse": print(PointerSpeed.selfTestReport())
    case "permissions": print(PermissionRequest.selfTestReport())
    case "settings":
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("settings-panel")
        print(SettingsPanel.selfTestReport(folder: i + 2 < args.count ? URL(fileURLWithPath: args[i + 2]) : folder))
    case "settings-live":
        let folder = URL(fileURLWithPath: i + 2 < args.count ? args[i + 2] : NSTemporaryDirectory())
        // Under the real run loop, as the icon and the panel need the app really running. Not from the main queue: blocks
        // the panel queues there couldn't run until the test had returned.
        app.setActivationPolicy(.accessory)
        RunLoop.main.perform {
            print(SettingsPanel.liveSelfTestReport(folder: folder))
            exit(0)
        }
        app.run()
    case "update": print(UpdateInstaller.selfTestReport(install: false))
    case "update-install": print(UpdateInstaller.selfTestReport(install: true))
    case "update-trust": print(UpdateInstaller.trustSelfTestReport(others: args[(i + 2)...].map { URL(fileURLWithPath: $0) }))
    default: print("unknown self-test: \(args[i + 1])")
    }
    exit(0)
}

app.setActivationPolicy(.accessory)
// Before the Eye Color Camera reads its settings: they used to live in camrelay's config file.
Settings.adoptCamrelaySettings()
let delegate = AppDelegate(lockWarning: LockWarning(timeoutOverride: timeoutOverride))
app.delegate = delegate
app.run()
