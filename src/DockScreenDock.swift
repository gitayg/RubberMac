import AppKit
import Synchronization

// What the Dock is doing, read without changing it, and the push that brings it to a screen.
enum DockScreenDock {
    typealias Edge = FullScreenDock.Edge

    private static let pushes = 60
    private static let pushInterval: TimeInterval = 0.015
    private static let pushDistance: CGFloat = 6

    // "Displays have separate Spaces" off: the Dock then lives on the main screen only and can't be moved.
    static var spansDisplays: Bool {
        CFPreferencesCopyAppValue("spans-displays" as CFString, "com.apple.spaces" as CFString) as? Bool == true
    }

    static var autohide: Bool {
        CFPreferencesCopyAppValue("autohide" as CFString, "com.apple.dock" as CFString) as? Bool == true
    }

    // The Dock's strip of icons (its AXList), in global coordinates. While hidden it sits just past its screen's edge.
    static func stripFrame() -> CGRect? {
        guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.processIdentifier else { return nil }
        let app = AX.app(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXChildrenAttribute as CFString, &value) == .success,
              let children = value as? [AXUIElement],
              let list = children.first(where: { AX.string($0, kAXRoleAttribute) == kAXListRole }) else { return nil }
        return AX.frame(of: list)
    }

    // Which of the screens the Dock is on now, nil if it can't be read.
    static func screen(among screens: [CGRect], edge: Edge = FullScreenDock.dockEdge()) -> Int? {
        stripFrame().flatMap { DockScreenGeometry.dockScreen(strip: $0, edge: edge, screens: screens) }
    }

    struct Push {
        var pushes = 0
        var arrived = false
        var milliseconds = 0
        // The pointer was moved away mid-way, by a hand.
        var interrupted = false
    }

    // Puts the pointer on the edge at the point and pushes past it in small steps, as a hand moving on does, until
    // `arrived` says the Dock is there; then puts the pointer back where it was. Runs off the main thread.
    static func push(at point: CGPoint, edge: Edge, maxPushes: Int = pushes, checkEvery: Int = 5, arrived: () -> Bool) -> Push {
        let saved = CGEvent(source: nil)?.location ?? point
        let source = CGEventSource(stateID: .hidSystemState)
        let start = Date()
        var result = Push()
        func post(_ delta: CGVector) {
            let event = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)
            event?.setIntegerValueField(.mouseEventDeltaX, value: Int64(delta.dx))
            event?.setIntegerValueField(.mouseEventDeltaY, value: Int64(delta.dy))
            event?.post(tap: .cghidEventTap)
        }
        post(.zero)
        for i in stride(from: 1, through: maxPushes, by: 1) {
            Thread.sleep(forTimeInterval: pushInterval)
            guard let at = CGEvent(source: nil)?.location, abs(at.x - point.x) <= 2, abs(at.y - point.y) <= 2 else {
                result.interrupted = true
                break
            }
            post(DockScreenGeometry.pushDelta(edge, pushDistance))
            result.pushes = i
            if i % checkEvery == 0, arrived() {
                result.arrived = true
                break
            }
        }
        if !result.arrived && !result.interrupted { result.arrived = arrived() }
        result.milliseconds = Int(-start.timeIntervalSinceNow * 1000)
        if !result.interrupted { CGWarpMouseCursorPosition(saved) }
        return result
    }
}

// The Dock's side, cached for the pointer guard: read again at most every two seconds, and never on the tap's thread.
final class DockScreenOrientation {
    private let state = Mutex<(edge: FullScreenDock.Edge, read: TimeInterval, reading: Bool)>((.bottom, -.infinity, false))
    private let queue = DispatchQueue(label: "dock screen orientation", qos: .utility)

    func refresh() {
        let edge = FullScreenDock.dockEdge()
        state.withLock { $0 = (edge, ProcessInfo.processInfo.systemUptime, false) }
    }

    var current: FullScreenDock.Edge {
        let now = ProcessInfo.processInfo.systemUptime
        let (edge, stale) = state.withLock { s -> (FullScreenDock.Edge, Bool) in
            let stale = now - s.read > 2 && !s.reading
            if stale { s.reading = true }
            return (s.edge, stale)
        }
        if stale { queue.async { [self] in refresh() } }
        return edge
    }
}
