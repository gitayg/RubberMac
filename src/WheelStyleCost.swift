import AppKit

// The handler runs in the mouse tap on the main thread, for every scroll while any switch is on, and ⌘ + wheel zoom is
// on out of the box: what it costs a scroll, timed over 10,000 made-up events on each path.
enum WheelStyleCost {
    static let events = 10_000
    static let limit = 20.0

    static func measure(_ check: WheelStyleChecks.Check) {
        // A real cache already holding a made-up app's menus, the path a ⌘ + wheel takes once an app's menus are read.
        let cache = ZoomMenuCache()
        cache.report = { _ in }
        cache.read = { _ in ZoomMenu(zoomIn: ZoomItem(title: "Zoom In", key: "+"), zoomOut: ZoomItem(title: "Zoom Out", key: "-")) }
        let pid: pid_t = 99_999
        let deadline = Date(timeIntervalSinceNow: 2)
        while Date() < deadline, case .reading = cache.lookup(pid) { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01)) }
        guard case .found = cache.lookup(pid) else { return check(false, "cost: the made-up app's menus are in the cache") }

        var presses = 0
        let handler = WheelStyleHandler(zoom: WheelZoom(lookup: cache.lookup, press: { _, _ in presses += 1 }))
        handler.zoom.front = { ("cost.made.up.app", pid) }
        func time(_ name: String, _ event: CGEvent, classic: Bool = false, steady: Bool = false) {
            handler.classic = classic
            handler.steady = steady
            handler.zoomOn = true
            let start = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<events { _ = handler.handle(.scrollWheel, event) }
            let micro = Double(DispatchTime.now().uptimeNanoseconds - start) / Double(events) / 1000
            check(micro < limit, "cost, \(name): \(String(format: "%.2f", micro)) µs a scroll")
        }
        let notch = WheelStyleChecks.scroll(lines: 1, fixed: 1, points: 13, continuous: true, flags: .maskCommand)
        time("⌘ + wheel, zooming with the app's menus cached (\(events) events, so nearly all held by the throttle)", notch)
        check(presses >= 1, "and it did step (\(presses) in all)")
        time("no modifier, only the zoom on (as installed)", WheelStyleChecks.scroll(lines: 1, fixed: 1, points: 13, continuous: true))
        // Natural scrolling read for real but taken as on, so every pass is made steady and turned round.
        handler.natural = { WheelStyle.naturalScrolling() || true }
        time("no modifier, classic and steady on too", WheelStyleChecks.scroll(lines: 1, fixed: 1, points: 13, continuous: true),
             classic: true, steady: true)
        time("⇧ + a trackpad swipe (counted, then left alone)",
             WheelStyleChecks.scroll(lines: 1, fixed: 0.4, points: 4, phase: 2, continuous: true, flags: .maskShift))
    }
}
