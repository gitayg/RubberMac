import AppKit

// Why RubberMAC wants a permission, said before macOS's own prompt, which can't give a reason.
enum PermissionRequest {
    case accessibility, screenRecording

    var title: String {
        switch self {
        case .accessibility: return "RubberMAC needs Accessibility to work with your windows and keys"
        case .screenRecording: return "Show pictures of your windows?"
        }
    }

    var why: String {
        switch self {
        case .accessibility:
            return """
                It's how RubberMAC runs Alt-Tab, snaps windows with ⌘ + arrows, opens the Dock menu and handles \
                shortcuts like Ctrl-C and Ctrl-V. Without it, those features don't work.

                The log never records the keys you type, and nothing you type leaves your Mac.

                Next, macOS asks you to turn on RubberMAC in System Settings.
                """
        case .screenRecording:
            return """
                Alt-Tab and the Dock menu can show a picture of each window, so you can tell them apart, and the \
                writing pad can read the window you're replying to. macOS calls the permission for this Screen \
                Recording.

                Window pictures are kept in memory only, and nothing leaves your Mac. Without it, RubberMAC still \
                works and shows each window's app icon and place on the screen instead.

                Next, turn on RubberMAC in System Settings.
                """
        }
    }

    func alert() -> NSAlert {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = why
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Not Now")
        return alert
    }

    // True when they chose to go on. A menu-bar app isn't in front by itself, and the question would open behind.
    func ask() -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        return alert().runModal() == .alertFirstButtonReturn
    }

    static func screenRecordingDue(hasPermission: Bool, alreadyAsked: Bool, accessibilityDone: Bool) -> Bool {
        !hasPermission && !alreadyAsked && accessibilityDone
    }
}
