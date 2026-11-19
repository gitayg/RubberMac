import AppKit
import Carbon.HIToolbox

// Windows' Win+Ctrl+←/→: ⌃⌘←/→ goes to the desktop on the left or right, full-screen apps included, one per press, at
// once rather than sliding. At either end it does nothing, as on Windows. Remote desktops and VMs keep the keys.
final class DesktopKeys: TapHandler {
    enum Direction: Equatable {
        case left, right
    }

    var isEnabled = false
    var isActive: Bool { isEnabled }

    // The system's side, swapped out by the self-test. Called on the main thread.
    var onMove: (Direction) -> Void = { Desktops.move($0) }
    var frontmost: () -> String? = { Frontmost.bundleID }

    // Arrows whose key-down was taken, so their repeats and key-up are swallowed too, even if ⌃⌘ was let go first.
    private var taken: Set<Int> = []

    func handle(_ type: CGEventType, _ event: CGEvent) -> CGEvent? {
        guard isEnabled, type == .keyDown || type == .keyUp else { return event }
        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        if type == .keyUp { return taken.remove(keyCode) == nil ? event : nil }
        if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 { return taken.contains(keyCode) ? nil : event }
        guard let direction = Self.direction(keyCode: keyCode, flags: event.flags.rawValue, app: frontmost()) else { return event }
        taken.insert(keyCode)
        DispatchQueue.main.async { [onMove] in onMove(direction) }
        return nil
    }

    func tapWasDisabled() {
        taken.removeAll()
    }

    static func direction(keyCode: Int, flags: UInt64, app: String?) -> Direction? {
        guard !AppLists.remote.contains(app ?? ""),
              flags & (Modifiers.control | Modifiers.command | Modifiers.option | Modifiers.shift) == Modifiers.control | Modifiers.command
        else { return nil }
        switch keyCode {
        case kVK_LeftArrow: return .left
        case kVK_RightArrow: return .right
        default: return nil
        }
    }
}

extension DesktopKeys.Direction: CustomStringConvertible {
    var description: String { self == .left ? "left" : "right" }
    var arrow: String { self == .left ? "←" : "→" }
}

// The desktops and full-screen apps of the screen with the menu bar, left to right, and the swipe between them. A
// swipe past either end wedges the Dock on macOS 27 (a black screen until it gives up), so none is ever made there.
enum Desktops {
    struct Row: Equatable {
        let display: String
        let spaces: [UInt64]
        let index: Int
    }

    enum Outcome: Equatable {
        case moved(to: Int, of: Int)
        case atEnd
        case unreadable
        case failed
    }

    // Right after a swipe the window server can still report the Space it left, so for this long the Space it went to
    // counts as the current one; a quick second press then goes one further instead of past the end.
    static let settleTime: TimeInterval = 1
    // Main thread only.
    private static var heading: (display: String, index: Int, at: Date)?

    @discardableResult
    static func move(_ direction: DesktopKeys.Direction, now: Date = Date()) -> Outcome {
        guard let row = row() else {
            log("desktops: ⌃⌘\(direction.arrow) did nothing, the list of desktops can't be read")
            return .unreadable
        }
        let guess = headingIndex(heading, for: row, now: now)
        guard let to = target(row, direction, heading: guess) else {
            log("desktops: ⌃⌘\(direction.arrow) did nothing, no desktop further \(direction) (on \((guess ?? row.index) + 1) of \(row.spaces.count))")
            return .atEnd
        }
        guard DesktopSwipe.post(direction) else {
            log("desktops: ⌃⌘\(direction.arrow) did nothing, the swipe couldn't be made")
            return .failed
        }
        heading = (row.display, to, now)
        log("desktops: ⌃⌘\(direction.arrow) → \(to + 1) of \(row.spaces.count)")
        return .moved(to: to, of: row.spaces.count)
    }

    // Where the last swipe went, while it still counts.
    static func headingIndex(_ heading: (display: String, index: Int, at: Date)?, for row: Row, now: Date) -> Int? {
        guard let heading, heading.display == row.display, now.timeIntervalSince(heading.at) < settleTime else { return nil }
        return heading.index
    }

    // The index to go to, nil at the end.
    static func target(_ row: Row, _ direction: DesktopKeys.Direction, heading: Int?) -> Int? {
        let to = (heading ?? row.index) + (direction == .left ? -1 : 1)
        return row.spaces.indices.contains(to) ? to : nil
    }

    static func row() -> Row? {
        guard let connection, let copyManagedDisplaySpaces,
              let displays = copyManagedDisplaySpaces(connection)?.takeRetainedValue() as? [[String: Any]] else { return nil }
        let menuBar = copyMenuBarDisplay?(connection)?.takeRetainedValue() as String?
        return row(in: displays, menuBarDisplay: menuBar, active: activeSpace.map { $0(connection) })
    }

    // The menu bar's display, or the first. Its current Space is the one it names, or the active one.
    static func row(in displays: [[String: Any]], menuBarDisplay: String?, active: UInt64?) -> Row? {
        let display = displays.first { $0["Display Identifier"] as? String == menuBarDisplay } ?? displays.first
        guard let display else { return nil }
        let spaces = (display["Spaces"] as? [[String: Any]] ?? []).compactMap(spaceID)
        let current = (display["Current Space"] as? [String: Any]).flatMap(spaceID) ?? active
        guard let current, let index = spaces.firstIndex(of: current) else { return nil }
        return Row(display: display["Display Identifier"] as? String ?? "", spaces: spaces, index: index)
    }

    private static func spaceID(_ space: [String: Any]) -> UInt64? {
        ((space["ManagedSpaceID"] ?? space["id64"]) as? NSNumber)?.uint64Value
    }

    private typealias MainConnection = @convention(c) () -> Int32
    private typealias ActiveSpace = @convention(c) (Int32) -> UInt64
    private typealias CopyManagedDisplaySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?
    private typealias CopyMenuBarDisplay = @convention(c) (Int32) -> Unmanaged<CFString>?
    private static let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    private static let connection = dlsym(skyLight, "SLSMainConnectionID").map { unsafeBitCast($0, to: MainConnection.self)() }
    private static let activeSpace = dlsym(skyLight, "SLSGetActiveSpace").map { unsafeBitCast($0, to: ActiveSpace.self) }
    private static let copyManagedDisplaySpaces = dlsym(skyLight, "SLSCopyManagedDisplaySpaces")
        .map { unsafeBitCast($0, to: CopyManagedDisplaySpaces.self) }
    private static let copyMenuBarDisplay = dlsym(skyLight, "SLSCopyActiveMenuBarDisplayIdentifier")
        .map { unsafeBitCast($0, to: CopyMenuBarDisplay.self) }
}
