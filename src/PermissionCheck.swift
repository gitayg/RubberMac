import Foundation

// What the Permissions page says for a given reading of the three permissions. Only logic and words: the reading itself
// is done elsewhere, and never asks.
struct PermissionCheck {
    enum Kind { case accessibility, screenRecording, finder }

    enum FinderState: Equatable {
        case on, off, notAskedYet

        // Anything but a plain yes or no (the consent not given yet, Finder not running) means macOS hasn't decided.
        init(status: OSStatus) {
            switch status {
            case noErr: self = .on
            case FinderWindow.notPermitted: self = .off
            default: self = .notAskedYet
            }
        }

        var word: String {
            switch self {
            case .on: return "on"
            case .off: return "off"
            case .notAskedYet: return "not asked yet"
            }
        }
    }

    struct Row {
        let kind: Kind
        let title: String
        // true or false for a switch's state; nil when macOS hasn't decided yet.
        let isOn: Bool?
        let state: String
        let note: String
        let hint: String?

        var offersTurnOn: Bool { isOn == false }
    }

    var accessibility: Bool
    var screenRecording: Bool
    // nil until the first reading is back from Finder's side.
    var finder: FinderState?
    var finderUsed: Bool

    var rows: [Row] {
        var rows = [
            Row(kind: .accessibility, title: "Accessibility", isOn: accessibility, state: accessibility ? "On" : "Off",
                note: accessibility ? Self.accessibilityUse : "\(Self.accessibilityUse) They don't work without it.",
                hint: accessibility ? nil : "If its switch is already on in System Settings, turn it off and on again."),
            Row(kind: .screenRecording, title: "Screen Recording (optional)", isOn: screenRecording, state: screenRecording ? "On" : "Off",
                note: screenRecording ? Self.screenUse : "\(Self.screenUse) Without it, windows show their app icon and place on the screen, and the pad can't read them.",
                hint: screenRecording ? nil : "If you just turned it on and it still says off, quit and reopen RubberMAC."),
        ]
        if finderUsed {
            switch finder {
            case .on?:
                rows.append(Row(kind: .finder, title: "Finder Control", isOn: true, state: "On", note: Self.finderUse, hint: nil))
            case .off?:
                rows.append(Row(kind: .finder, title: "Finder Control", isOn: false, state: "Off",
                                note: "\(Self.finderUse) Without it, a path opens in a new Finder window.", hint: nil))
            case .notAskedYet?:
                rows.append(Row(kind: .finder, title: "Finder Control", isOn: nil,
                                state: "macOS asks the first time you paste a path", note: Self.finderUse, hint: nil))
            case nil:
                rows.append(Row(kind: .finder, title: "Finder Control", isOn: nil, state: "Checking…", note: Self.finderUse, hint: nil))
            }
        }
        return rows
    }

    // States only; the log never says more.
    var logLine: String {
        var parts = ["accessibility \(accessibility ? "on" : "off")", "screen recording \(screenRecording ? "on" : "off")"]
        if finderUsed, let finder { parts.append("finder \(finder.word)") }
        return "permissions: " + parts.joined(separator: ", ")
    }

    // The time is part of it so that a re-read that changes nothing still visibly did something.
    static func checkedNote(at checked: Date, now: Date) -> String {
        let time = DateFormatter.localizedString(from: checked, dateStyle: .none, timeStyle: .medium)
        return now.timeIntervalSince(checked) < 60 ? "Checked just now, at \(time)" : "Last checked at \(time)"
    }

    private static let accessibilityUse = "Runs Alt-Tab, window snapping, the Dock menu and shortcuts like Ctrl-C and Ctrl-V."
    private static let screenUse = "Adds window pictures to Alt-Tab and the Dock menu, and lets the writing pad read the window you're replying to."
    private static let finderUse = "Lets a pasted path or the address bar move the Finder window."
}
