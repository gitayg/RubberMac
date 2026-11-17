import AppKit

// New windows open on the screen you're using: a file or app opened on one screen opens there, not on another one, and
// chosen apps always open on a chosen screen. It only moves windows as they first appear; Window Layouts, which puts
// windows back after the screens change, moves them only once the screens are still, and this moves nothing until then.
final class OpenOnScreen: Feature {
    static let shared = OpenOnScreen()

    struct App: Equatable {
        let bundleID: String
        let name: String
    }

    let mover = OpenOnScreenMover()
    private var started = false

    var wantsAccess: Bool { Settings.openOnScreenEnabled || !Settings.openOnScreenRules.isEmpty }

    func start() {
        started = true
        apply()
    }

    func restartTaps() {
        mover.restart()
    }

    // After a setting changed on the Windows page, at once.
    func apply() {
        guard started else { return }
        mover.configure(switchOn: Settings.openOnScreenEnabled, rules: Settings.openOnScreenRules)
    }

    // Running ordinary apps, by name, each once.
    static func runningApps() -> [App] {
        let me = ProcessInfo.processInfo.processIdentifier
        var seen = Set<String>()
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != me }
            .compactMap { app in app.bundleIdentifier.map { App(bundleID: $0, name: app.localizedName ?? $0) } }
            .filter { seen.insert($0.bundleID).inserted }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func selfTestReport() -> String { OpenOnScreenSelfTest.report() }
    static func liveSelfTestReport() -> String { OpenOnScreenLive.report() }
}
