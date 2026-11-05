import AppKit
import Synchronization

// In a full-screen app the Dock comes up only for a firm push against the screen's edge; just moving the pointer
// there, even right down to the edge, does nothing. When the pointer reaches the Dock's edge over a full-screen
// window, this adds the push. Watches pointer moves on the pointer tap's own thread; the checks and the push run on
// a queue of their own.
final class FullScreenDock: TapHandler {
    enum Edge: String { case bottom, left, right }

    var isEnabled = false
    var isActive: Bool { isEnabled }

    // Marks the moves this posts, so they don't count as the pointer arriving.
    private static let marker: Int64 = 0x5354_444F_434B  // "STDOCK"
    private static let pushes = 30
    private static let pushInterval: TimeInterval = 0.015
    private static let pushDistance: Int64 = 6

    private var arrived: Edge?
    private let busy = Atomic<Bool>(false)
    private let queue = DispatchQueue(label: "full-screen dock", qos: .userInteractive)

    func handle(_ type: CGEventType, _ event: CGEvent) -> CGEvent? {
        guard isEnabled, type == .mouseMoved, event.getIntegerValueField(.eventSourceUserData) != Self.marker else { return event }
        let edge = Self.edge(at: event.location)
        if let edge, edge != arrived, !busy.load(ordering: .relaxed) {
            busy.store(true, ordering: .relaxed)
            queue.async { [self] in
                defer { busy.store(false, ordering: .relaxed) }
                guard Self.dockEdge() == edge, Self.frontIsFullScreen(), !Self.dockIsShown() else { return }
                Self.push(toward: edge)
            }
        }
        arrived = edge
        return event
    }

    // The outer screen edge the point is on, if any; an edge that runs into another display isn't one.
    static func edge(at point: CGPoint) -> Edge? {
        guard let bounds = displayBounds(at: point) else { return nil }
        let candidates: [(Edge, Bool, CGPoint)] = [
            (.bottom, point.y >= bounds.maxY - 1, CGPoint(x: point.x, y: bounds.maxY + 1)),
            (.left, point.x <= bounds.minX, CGPoint(x: bounds.minX - 1, y: point.y)),
            (.right, point.x >= bounds.maxX - 1, CGPoint(x: bounds.maxX + 1, y: point.y)),
        ]
        return candidates.first { $0.1 && displayBounds(at: $0.2) == nil }?.0
    }

    private static func displayBounds(at point: CGPoint) -> CGRect? {
        var display: CGDirectDisplayID = 0
        var count: UInt32 = 0
        guard CGGetDisplaysWithPoint(point, 1, &display, &count) == .success, count > 0 else { return nil }
        return CGDisplayBounds(display)
    }

    static func dockEdge() -> Edge {
        let value = CFPreferencesCopyAppValue("orientation" as CFString, "com.apple.dock" as CFString) as? String
        return value.flatMap(Edge.init(rawValue:)) ?? .bottom
    }

    static func frontIsFullScreen() -> Bool {
        let pid = Frontmost.pid
        guard pid > 0, let window = AX.focusedWindow(of: pid) else { return false }
        return AX.bool(window, "AXFullScreen") == true
    }

    // While the Dock is up, its window (screen-sized, at the Dock's level) is on screen; while hidden, it isn't.
    static func dockIsShown() -> Bool {
        let level = Int(CGWindowLevelForKey(.dockWindow))
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        return windows.contains { $0[kCGWindowOwnerName as String] as? String == "Dock" && $0[kCGWindowLayer as String] as? Int == level }
    }

    // Moves that stay on the edge but keep going past it, as a hand pushing the pointer into the edge does. Stops
    // as soon as the Dock is up or the pointer leaves the edge.
    private static func push(toward edge: Edge) {
        let source = CGEventSource(stateID: .hidSystemState)
        for i in 0..<pushes {
            guard let at = CGEvent(source: nil)?.location, Self.edge(at: at) == edge else { return }
            if i % 5 == 4, dockIsShown() { return }
            let event = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: at, mouseButton: .left)
            switch edge {
            case .bottom: event?.setIntegerValueField(.mouseEventDeltaY, value: pushDistance)
            case .left: event?.setIntegerValueField(.mouseEventDeltaX, value: -pushDistance)
            case .right: event?.setIntegerValueField(.mouseEventDeltaX, value: pushDistance)
            }
            event?.setIntegerValueField(.eventSourceUserData, value: marker)
            event?.post(tap: .cghidEventTap)
            Thread.sleep(forTimeInterval: pushInterval)
        }
    }
}
