import AppKit

// Where a new window goes: whether it moves, to which screen, at what size. Pure, on frames in the Accessibility space
// (top-left origin, y down), so the self-test can hand it made-up screens.
enum OpenOnScreenPlan {
    struct Screen: Equatable {
        // Vendor, model and serial, as CameraArea keys a screen.
        let key: String
        let name: String
        let frame: CGRect
        let visible: CGRect
    }

    // What Accessibility says about a new window.
    struct Window: Equatable {
        var role: String? = kAXWindowRole
        var subrole: String? = kAXStandardWindowSubrole
        var fullScreen = false
        var minimized = false
        var frame: CGRect
    }

    struct Context {
        var screens: [Screen]
        var pointer: CGPoint
        // The app's chosen screen, by key.
        var rule: String?
        // It appeared right after the user opened its app or a file, with the switch on.
        var opening: Bool
        var mouseDown = false
        // Where it was when a mouse button was first found down: moved since, it's being dragged.
        var heldAt: CGRect?
        var screensChanging = false
        var showsFullScreen: (Screen) -> Bool = { _ in false }
        // It's a tab added to a window that was already open, as apps do with "Prefer tabs when opening documents".
        var isTabOfOlderWindow: () -> Bool = { false }
    }

    enum Reason: String {
        case notOrdinary = "not an ordinary window"
        case fullScreen = "full screen"
        case minimized = "minimized"
        case oneScreen = "one screen"
        case screensChanging = "the screens are changing"
        case notOpening = "not right after the user opened something"
        case ruleWaits = "its app's screen isn't connected"
        case offScreen = "on no screen"
        case alreadyThere = "already on its screen"
        case dragged = "being dragged"
        case tabOfOlderWindow = "a new tab in a window that was already open"
        case targetFullScreen = "its screen shows a full-screen app"
    }

    enum Outcome: Equatable {
        case move(to: Int, frame: CGRect)
        // A mouse button is down: look again in a moment.
        case wait
        case leave(Reason)
    }

    static func decide(_ window: Window, _ context: Context) -> Outcome {
        guard window.role == kAXWindowRole, window.subrole == kAXStandardWindowSubrole else { return .leave(.notOrdinary) }
        guard !window.fullScreen else { return .leave(.fullScreen) }
        guard !window.minimized else { return .leave(.minimized) }
        let screens = context.screens
        guard screens.count >= 2 else { return .leave(.oneScreen) }
        // macOS and Window Layouts move windows about while screens come and go.
        guard !context.screensChanging else { return .leave(.screensChanging) }
        // A rule whose screen isn't connected waits; meanwhile the window is the switch's to place, as any other.
        let chosen = context.rule.flatMap { key in screens.firstIndex { $0.key == key } }
        guard let target = chosen ?? (context.opening ? screen(at: context.pointer, screens) : nil) else {
            return .leave(context.rule == nil ? .notOpening : .ruleWaits)
        }
        guard let from = screen(of: window.frame, screens) else { return .leave(.offScreen) }
        guard from != target else { return .leave(.alreadyThere) }
        if let held = context.heldAt, held != window.frame { return .leave(.dragged) }
        guard !context.mouseDown else { return .wait }
        // Moving it would take that window, and its other tabs, along.
        guard !context.isTabOfOlderWindow() else { return .leave(.tabOfOlderWindow) }
        // It would land on that screen's desktop, hidden behind the full-screen app.
        guard !context.showsFullScreen(screens[target]) else { return .leave(.targetFullScreen) }
        return .move(to: target, frame: fit(window.frame, from: screens[from].visible, to: screens[target].visible))
    }

    // The same size, shrunk if it doesn't fit; as far across and down the room it has as it was on its own screen,
    // so a window in a corner stays in that corner and a centred one stays centred.
    static func fit(_ frame: CGRect, from: CGRect, to: CGRect) -> CGRect {
        let width = min(frame.width, to.width), height = min(frame.height, to.height)
        typealias Span = (start: CGFloat, length: CGFloat)
        func along(_ start: CGFloat, _ length: CGFloat, _ room: Span, _ into: Span, _ newLength: CGFloat) -> CGFloat {
            let spare = room.length - length
            let share = spare > 0 ? min(max((start - room.start) / spare, 0), 1) : 0.5
            return (into.start + share * (into.length - newLength)).rounded()
        }
        return CGRect(x: along(frame.minX, frame.width, (from.minX, from.width), (to.minX, to.width), width),
                      y: along(frame.minY, frame.height, (from.minY, from.height), (to.minY, to.height), height),
                      width: width, height: height)
    }

    // The screen holding most of the window; nil if it's on none.
    static func screen(of frame: CGRect, _ screens: [Screen]) -> Int? {
        let areas = screens.map { screen -> CGFloat in
            let overlap = screen.frame.intersection(frame)
            return overlap.isNull ? 0 : overlap.width * overlap.height
        }
        guard let best = areas.indices.max(by: { areas[$0] < areas[$1] }), areas[best] > 0 else { return nil }
        return best
    }

    // The screen under the pointer, or the nearest one when it's in a gap between screens.
    static func screen(at point: CGPoint, _ screens: [Screen]) -> Int? {
        if let inside = screens.firstIndex(where: { $0.frame.contains(point) }) { return inside }
        func distance(_ rect: CGRect) -> CGFloat {
            hypot(max(rect.minX - point.x, 0, point.x - rect.maxX), max(rect.minY - point.y, 0, point.y - rect.maxY))
        }
        return screens.indices.min { distance(screens[$0].frame) < distance(screens[$1].frame) }
    }

    // MARK: This Mac

    static func connectedScreens() -> [Screen] {
        zip(NSScreen.screens, WindowSnapper.screenAreas()).compactMap { screen, area in
            screen.displayID.map { Screen(key: CameraArea.key(of: $0), name: screen.localizedName, frame: area.frame, visible: area.visible) }
        }
    }

    static func pointer() -> CGPoint {
        let point = NSEvent.mouseLocation
        return CGPoint(x: point.x, y: (NSScreen.screens.first?.frame.height ?? 0) - point.y)
    }

    // A full-screen app's window covers its whole screen, menu bar included, which an ordinary window doesn't.
    static func showsFullScreen(_ screen: Screen) -> Bool {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return windows.contains { info in
            (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0
                && (info[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) } == screen.frame
        }
    }
}
