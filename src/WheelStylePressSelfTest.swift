import AppKit

// --selftest wheelstyle, the presses: ZoomPresser with a made-up press, question and menus in place of Accessibility's,
// so nothing is pressed or read. One at a time and in order, the caller never kept waiting, an app that's slow to answer
// gets no more than `limit` and one that doesn't answer no press, and an item gone since its menus were read is found
// again.
extension WheelStyleChecks {
    // What the made-up press saw, from whichever thread it ran on.
    final class PressLog {
        private let lock = NSLock()
        private var lines: [String] = []
        func add(_ line: String) { lock.lock(); lines.append(line); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return lines }
        // Until `count` lines are in, for up to 2 s.
        func wait(_ count: Int) -> [String] {
            let end = Date(timeIntervalSinceNow: 2)
            while all.count < count, Date() < end { Thread.sleep(forTimeInterval: 0.005) }
            return all
        }
    }

    // Made-up elements, told apart by the pid each is made for; creating one asks no app anything.
    static let pressNames = ["Zoom In", "Zoom Out", "in 1", "out 2", "in 3", "Zoom In again", "Zoom Out again", "Zoom In third"]
    static func madeUp(_ name: String) -> AXUIElement { AXUIElementCreateApplication(pid_t(70_000 + pressNames.firstIndex(of: name)!)) }
    static func madeUpName(_ element: AXUIElement) -> String {
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        return pressNames[Int(pid) - 70_000]
    }
    static func pressItem(_ title: String, element name: String? = nil, key: String? = nil) -> ZoomItem {
        ZoomItem(title: title, key: key, element: madeUp(name ?? title))
    }

    static func presses(_ check: Check) {
        // A zoom in that takes the app 30 ms, then a zoom out of 15 ms and a zoom in of none: started together, each
        // would finish in the opposite order.
        let ordered = ZoomPresser()
        ordered.limit = 3
        ordered.ask = { _ in .success }
        let log = PressLog()
        let takes = ["in 1": 0.03, "out 2": 0.015, "in 3": 0.0]
        ordered.pressElement = { element in
            log.add("start \(madeUpName(element))")
            Thread.sleep(forTimeInterval: takes[madeUpName(element)] ?? 0)
            log.add("end \(madeUpName(element))")
            return .success
        }
        for title in ["in 1", "out 2", "in 3"] { ordered.press(pressItem(title), in: 4242) }
        let order = log.wait(6)
        check(order == ["start in 1", "end in 1", "start out 2", "end out 2", "start in 3", "end in 3"],
              "presses one at a time, in the order they came, the slow first one before the quick ones: \(order.joined(separator: ", "))")

        // An app slow to answer: each press waits for it up to 0.3 s.
        let stuck = ZoomPresser()
        stuck.ask = { _ in .success }
        let release = DispatchSemaphore(value: 0)
        let pressed = PressLog()
        stuck.pressElement = { element in
            _ = release.wait(timeout: .now() + 0.3)
            pressed.add(madeUpName(element))
            return .success
        }
        var accepted: [Bool] = []
        var slowest = 0.0
        for title in ["Zoom In", "Zoom Out", "Zoom In", "Zoom Out", "Zoom In"] {
            let start = DispatchTime.now().uptimeNanoseconds
            accepted.append(stuck.press(pressItem(title), in: 4242))
            slowest = max(slowest, Double(DispatchTime.now().uptimeNanoseconds - start) / 1000)
        }
        check(slowest < 5000, "with the app slow to answer, a press hands over and returns at once (slowest \(String(format: "%.0f", slowest)) µs), "
              + "never waiting on the tap's thread")
        check(accepted == [true, true, false, false, false],
              "and only \(ZoomPresser.limit) are kept, the one under way and one waiting; the next three are dropped: \(accepted)")
        release.signal()
        release.signal()
        _ = pressed.wait(2)
        Thread.sleep(forTimeInterval: 0.05)
        check(pressed.all == ["Zoom In", "Zoom Out"], "once it answers, the two kept land in order and the dropped never do: \(pressed.all)")
        let again = stuck.press(pressItem("Zoom Out"), in: 4242)
        release.signal()
        check(again && pressed.wait(3) == ["Zoom In", "Zoom Out", "Zoom Out"], "and the next press is taken again")

        // Through the handler: a fast spin over a slow app reaches it with no more than the limit.
        let hung = ZoomPresser()
        hung.ask = { _ in .success }
        let hold = DispatchSemaphore(value: 0)
        let reached = PressLog()
        hung.pressElement = { element in
            _ = hold.wait(timeout: .now() + 0.3)
            reached.add(madeUpName(element))
            return .success
        }
        var steps = 0, kept = 0
        let menu = ZoomMenu(zoomIn: pressItem("Zoom In"), zoomOut: pressItem("Zoom Out"))
        let handler = WheelStyleHandler(zoom: WheelZoom(lookup: { _ in .found(menu) }, press: { item, pid in
            steps += 1
            if hung.press(item, in: pid) { kept += 1 }
        }))
        handler.zoomOn = true
        handler.natural = { false }
        handler.zoom.front = { ("com.google.Chrome", 4242) }
        var time = 100.0
        handler.zoom.now = { time }
        for _ in 0..<20 {
            time += 0.025
            _ = handler.handle(.scrollWheel, scroll(lines: 1, fixed: 0.1, points: 1, flags: .maskCommand))
        }
        hold.signal()
        hold.signal()
        let spun = reached.wait(2)
        check(steps == 7 && kept == 2 && spun == ["Zoom In", "Zoom In"],
              "a fast spin, 20 notches 25 ms apart, over a slow app: \(steps) steps, \(kept) kept and pressed, the rest dropped")

        foundAgain(check)
    }

    // Each item is asked whether it's enabled first. The app built its menus anew since they were read, as Claude does:
    // the item read before is gone. Or the app doesn't answer.
    static func foundAgain(_ check: Check) {
        let presser = ZoomPresser()
        let log = PressLog()
        var asks: [String: AXError] = [:]
        var reads = 0
        var menus: [ZoomMenus.Entry] = []
        presser.ask = { element in asks[madeUpName(element)] ?? .success }
        presser.pressElement = { element in
            log.add(madeUpName(element))
            return .success
        }
        presser.read = { pid in
            reads += 1
            log.add("read \(pid)")
            return menus
        }
        func pressing(_ item: ZoomItem) -> [String] {
            let before = log.all.count
            presser.press(item, in: 4242)
            presser.queue.sync {}
            return Array(log.all.dropFirst(before))
        }
        // As read again: Bigger with ⌘+ in another menu, then the Zoom In and Zoom Out the cache held, as new elements.
        func entry(_ title: String, _ key: String, _ element: String, menu: Int) -> ZoomMenus.Entry {
            ZoomMenus.Entry(item: ZoomItem(title: title, key: key, element: madeUp(element)), menu: menu)
        }
        menus = [entry("Bigger", "+", "in 1", menu: 2), entry("Zoom In", "+", "Zoom In again", menu: 3),
                 entry("Zoom Out", "-", "Zoom Out again", menu: 3)]
        let zoomIn = pressItem("Zoom In", key: "+"), zoomOut = pressItem("Zoom Out", key: "-")

        check(pressing(zoomIn) == ["Zoom In"], "an item that's still there is pressed once, its menus not read again")
        asks = ["Zoom In": .invalidUIElement, "Zoom Out": .invalidUIElement]
        check(pressing(zoomIn) == ["read 4242", "Zoom In again"],
              "one gone: the app's menus are read again and the item with the same title and shortcut pressed instead, not Bigger")
        check(pressing(zoomOut) == ["Zoom Out again"] && pressing(zoomIn) == ["Zoom In again"] && reads == 1,
              "the items read again are kept: the next presses use them with no read (\(reads) in all)")
        asks["Zoom In again"] = .invalidUIElement
        menus = [entry("Zoom In", "+", "Zoom In third", menu: 3)]
        check(pressing(zoomIn) == ["read 4242", "Zoom In third"], "built anew again: the kept one is gone too, so they're read once more")
        asks = ["Zoom In": .invalidUIElement, "Zoom In third": .invalidUIElement]
        menus = [entry("Zoom Out", "-", "Zoom Out again", menu: 3)]
        check(pressing(zoomIn) == ["read 4242"], "and an item no longer in its menus at all is pressed nowhere")
        asks = ["Zoom In": .cannotComplete]
        check(pressing(zoomIn).isEmpty, "an app that doesn't answer the question gets no press, as one sent now would land when it wakes")
        asks = ["Zoom In": .attributeUnsupported]
        check(pressing(zoomIn) == ["Zoom In"], "an item that can't say whether it's enabled is pressed all the same")
    }
}
