import AppKit

// Lost windows: brings windows that are off every screen, or bigger than theirs, back onto a screen; and makes an app
// forget the window sizes and places it saved, so its windows open fresh.
final class WindowReset: Feature {
    static let shared = WindowReset()

    // What each button did last, for its row's note. For this session only.
    private(set) var bringBackNote: String?
    private(set) var forgetNote: String?
    private(set) var isBringingBack = false
    private(set) var isForgetting = false

    // Two buttons, nothing that runs by itself: each asks for what it needs when pressed.
    var wantsAccess: Bool { false }
    func start() {}
    func restartTaps() {}

    // Off the main thread, as a busy app can take a second to answer. done runs on the main thread.
    func bringBack(done: @escaping () -> Void) {
        guard !isBringingBack else { return }
        isBringingBack = true
        let screens = WindowSnapper.screenAreas()
        let apps = WindowResetMover.appsInUse()
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = WindowResetMover.bringBack(WindowResetMover.ordinaryWindows(of: apps), screens: screens, apply: true)
            DispatchQueue.main.async {
                self.isBringingBack = false
                self.bringBackNote = outcome.note
                log(outcome.logLine)
                done()
            }
        }
    }

    func forget(_ app: WindowResetSavedFrames.App, isOpen: Bool, done: @escaping () -> Void) {
        guard !isForgetting else { return }
        isForgetting = true
        forgetNote = isOpen ? "Quitting \(app.name)…" : "Forgetting \(app.name)'s window sizes…"
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = WindowResetForget.run(app, .real())
            DispatchQueue.main.async {
                self.isForgetting = false
                self.forgetNote = outcome.note(app.name)
                log(outcome.logLine(app.name))
                done()
            }
        }
    }

    static func selfTestReport() -> String { WindowResetSelfTest.report() }
    static func liveSelfTestReport() -> String { WindowResetLiveSelfTest.report() }
}

extension AppDelegate {
    // Sections at the end of the Windows page, after Background Windows.
    func windowResetSections(_ facts: SettingsFacts) -> [SettingsSection] {
        let reset = WindowReset.shared
        return windowResetSections(facts, bringBackNote: reset.bringBackNote, forgetNote: reset.forgetNote,
                                   bringingBack: reset.isBringingBack, forgetting: reset.isForgetting)
    }
}
