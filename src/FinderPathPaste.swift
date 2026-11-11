import AppKit
import Carbon.HIToolbox

// ⌘V (or Ctrl-V) in a Finder window with a path on the clipboard goes to that folder in the same window, without
// ⌘⇧G. A path to a file goes to its folder and selects it. Takes plain paths, ~, file:// links, and paths copied
// in quotes or with \-escaped spaces. Pasting into a text box in Finder (renaming, search, Go to Folder) and
// pasting copied files work as before.
final class FinderPathPaste: TapHandler {
    enum Destination: Equatable {
        case folder(URL)
        case item(URL)
    }

    enum Outcome: Equatable {
        case moved, selected, openedNewWindow, failed(OSStatus)
    }

    var isEnabled = false
    var isActive: Bool { isEnabled }
    // Set once Finder has said no, so the panel can offer the setting.
    private(set) var isDenied = false
    private(set) var lastOutcome: Outcome?

    private var swallowing = false
    private let queue = DispatchQueue(label: "finder path paste")
    private static let textRoles: Set<String> = [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole]

    func handle(_ type: CGEventType, _ event: CGEvent) -> CGEvent? {
        guard isEnabled, type == .keyDown || type == .keyUp,
              event.getIntegerValueField(.keyboardEventKeycode) == kVK_ANSI_V else { return event }
        // The V's own key-up and repeats go too, once its key-down was taken.
        if type == .keyUp || event.getIntegerValueField(.keyboardEventAutorepeat) != 0 {
            let swallowed = swallowing
            if type == .keyUp { swallowing = false }
            return swallowed ? nil : event
        }
        let held = event.flags.rawValue & (Modifiers.command | Modifiers.control | Modifiers.option | Modifiers.shift)
        let finder = Frontmost.pid
        guard held == Modifiers.command, Frontmost.bundleID == "com.apple.finder",
              let destination = Self.destination(on: .general),
              Self.isEditingText(in: finder) == false else { return event }
        swallowing = true
        let inWindow = Self.hasBrowserWindow(finder)
        queue.async { [weak self] in self?.go(to: destination, inWindow: inWindow) }
        return nil
    }

    func tapWasDisabled() {
        swallowing = false
    }

    func clearDenied() {
        isDenied = false
    }

    // Copied files stay a paste of files; only text that names something on disk is a path.
    static func destination(on board: NSPasteboard) -> Destination? {
        let types = board.types ?? []
        guard !types.contains(.fileURL), types.contains(.string), let text = board.string(forType: .string) else { return nil }
        return destination(from: text)
    }

    static func destination(from text: String) -> Destination? {
        var path = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, path.utf8.count <= Int(PATH_MAX) else { return nil }
        if path.count >= 2, let quote = path.first, quote == "\"" || quote == "'", path.last == quote {
            path = String(path.dropFirst().dropLast())
        }
        if path.hasPrefix("file:") {
            guard let url = URL(string: path), url.isFileURL else { return nil }
            path = url.path(percentEncoded: false)
        } else if path.hasPrefix("~") {
            path = (path as NSString).expandingTildeInPath
        }
        guard path.hasPrefix("/") else { return nil }
        // As copied from a terminal: My\ Folder. Tried second, since a backslash can be part of a name.
        let unescaped = path.replacingOccurrences(of: "\\\\(.)", with: "$1", options: .regularExpression)
        for candidate in [path, unescaped] {
            var isFolder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: candidate, isDirectory: &isFolder) else { continue }
            let url = URL(fileURLWithPath: candidate)
            // An app or other package is shown in its folder, not opened up.
            return isFolder.boolValue && !NSWorkspace.shared.isFilePackage(atPath: candidate) ? .folder(url) : .item(url)
        }
        return nil
    }

    // nil when Finder didn't answer in time, which leaves the paste to Finder.
    static func isEditingText(in pid: pid_t) -> Bool? {
        let app = AX.app(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let focused = value as! AXUIElement
        AXUIElementSetMessagingTimeout(focused, 0.25)
        if textRoles.contains(AX.string(focused, kAXRoleAttribute) ?? "") { return true }
        var range: CFTypeRef?
        return AXUIElementCopyAttributeValue(focused, kAXSelectedTextRangeAttribute as CFString, &range) == .success
    }

    // A folder window has the focus, rather than the desktop.
    private static func hasBrowserWindow(_ pid: pid_t) -> Bool {
        AX.focusedWindow(of: pid).flatMap { AX.string($0, kAXSubroleAttribute) } == kAXStandardWindowSubrole
    }

    // Runs on `queue`: Finder's answer, and the first time the user's, are waited for here.
    private func go(to destination: Destination, inWindow: Bool) {
        let outcome = Self.move(to: destination, inWindow: inWindow)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            lastOutcome = outcome
            switch outcome {
            case .moved, .selected:
                isDenied = false
                log("finder paste: went to a pasted \(outcome == .moved ? "folder" : "file's folder")")
            case .failed(let status):
                isDenied = status == FinderWindow.notPermitted
                log("finder paste: couldn't move the window (\(status)), opening the path in a new one")
                fallthrough
            case .openedNewWindow:
                Self.openOnItsOwn(destination)
            }
        }
    }

    // Takes Finder's front window to the folder, and selects a file there. Also used by the address bar. Waits for
    // Finder's answer, and the first time the user's, so call it off the main thread.
    static func move(to destination: Destination, inWindow: Bool) -> Outcome {
        guard inWindow else { return .openedNewWindow }
        let folder: URL, item: URL?
        switch destination {
        case .folder(let url): (folder, item) = (url, nil)
        case .item(let url): (folder, item) = (url.deletingLastPathComponent(), url)
        }
        let permission = FinderWindow.permission(ask: true)
        do {
            guard permission == noErr else { throw FinderWindow.Failure(status: permission) }
            try FinderWindow.show(folder)
            if let item { try FinderWindow.select(item) }
            return item == nil ? .moved : .selected
        } catch {
            return .failed((error as? FinderWindow.Failure)?.status ?? OSStatus(errAEEventFailed))
        }
    }

    // Without a window to move, or without leave to move it, the folder opens on its own. On the main thread.
    static func openOnItsOwn(_ destination: Destination) {
        switch destination {
        case .folder(let url): NSWorkspace.shared.open(url)
        case .item(let url): NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
}
