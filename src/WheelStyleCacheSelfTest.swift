import AppKit

// Part of --selftest wheelstyle: the cache of each app's zoom items with made-up reads, so no app is looked at. An app
// that has just opened has no menu bar to read for a moment (Claude, as it relaunched, read in 0 ms as having no zoom,
// and kept that answer); that's tried again, not taken as no zoom.
extension WheelStyleChecks {
    static func cache(_ check: Check) {
        let zoom = ZoomMenu(zoomIn: ZoomItem(title: "Zoom In", key: "+"), zoomOut: ZoomItem(title: "Zoom Out", key: "-"))
        func describe(_ lookup: ZoomLookup) -> String {
            switch lookup {
            case .reading: return "reading"
            case .none: return "none"
            case .found(let menu): return "found \(menu.zoomIn.shortcut)/\(menu.zoomOut.shortcut)"
            }
        }
        // A cache whose reads answer from a list, whose waits are kept to be run by hand, and whose clock is made up.
        final class Rig {
            let cache = ZoomMenuCache()
            var answers: [ZoomMenuCache.Read] = []
            var reads = 0
            var reports: [String] = []
            var waits: [(TimeInterval, () -> Void)] = []
            var time = 1000.0
            init() {
                cache.read = { [unowned self] _ in
                    reads += 1
                    return answers.isEmpty ? .failed : answers.removeFirst()
                }
                cache.report = { [unowned self] in reports.append($0) }
                cache.after = { [unowned self] delay, work in waits.append((delay, work)) }
                cache.now = { [unowned self] in time }
            }
            // Until the background read has come back to the main thread.
            func settle() {
                cache.reader.sync {}
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
            }
            func runWaits() {
                let now = waits
                waits = []
                for (_, work) in now { work() }
                settle()
            }
        }

        let launch = Rig()
        launch.answers = [.failed, .read(zoom)]
        let first = describe(launch.cache.lookup(7))
        launch.settle()
        let afterFail = describe(launch.cache.lookup(7))
        check(first == "reading" && afterFail == "reading",
              "an app just opened, its menus not readable yet: still being read, not taken as having no zoom (\(first), then \(afterFail))")
        check(launch.waits.map(\.0) == [ZoomMenuCache.retry] && launch.reports.isEmpty,
              "and tried again in \(ZoomMenuCache.retry) s without waiting for a scroll, nothing logged yet (\(launch.waits.map(\.0)), \(launch.reports))")
        launch.runWaits()
        check(describe(launch.cache.lookup(7)) == "found ⌘+/⌘-" && launch.reads == 2,
              "the second try reads its Zoom In and Zoom Out: \(describe(launch.cache.lookup(7))) after \(launch.reads) reads")
        check(launch.reports.count == 1 && launch.reports.first?.hasSuffix("after 2 tries)") == true,
              "one log line, saying it took two tries: \(launch.reports.first ?? "none")")
        check(launch.waits.isEmpty, "and no more tries once it's read")

        let never = Rig()
        _ = never.cache.lookup(8)
        never.settle()
        var rounds = 0
        while !never.waits.isEmpty && rounds < 100 {
            never.runWaits()
            rounds += 1
        }
        check(never.reads == ZoomMenuCache.tries && describe(never.cache.lookup(8)) == "none",
              "an app whose menus never can be read: \(never.reads) tries, then taken as having none (\(describe(never.cache.lookup(8))))")
        check(never.reports == ["wheel zoom: pid 8's menus couldn't be read in \(ZoomMenuCache.tries) tries; trying again in \(Int(ZoomMenuCache.freshNone)) s"],
              "one log line for it: \(never.reports.first ?? "none")")
        never.time += ZoomMenuCache.freshNone + 1
        never.answers = [.read(zoom)]
        _ = never.cache.lookup(8)
        never.settle()
        check(describe(never.cache.lookup(8)) == "found ⌘+/⌘-", "read again \(Int(ZoomMenuCache.freshNone)) s later, when it can be: found")

        let plain = Rig()
        plain.answers = [.read(nil)]
        _ = plain.cache.lookup(9)
        plain.settle()
        check(describe(plain.cache.lookup(9)) == "none" && plain.waits.isEmpty && plain.reads == 1,
              "an app read with no zoom in its menus: none at once, no tries again (\(plain.reads) read)")

        let kept = Rig()
        kept.answers = [.read(zoom)]
        _ = kept.cache.lookup(10)
        kept.settle()
        kept.time += ZoomMenuCache.fresh + 1
        kept.answers = [.failed]
        _ = kept.cache.lookup(10)
        kept.settle()
        check(describe(kept.cache.lookup(10)) == "found ⌘+/⌘-" && kept.waits.isEmpty && kept.reads == 2,
              "an app read before, whose read again fails (busy): keeps its zoom (\(describe(kept.cache.lookup(10))), \(kept.reads) reads)")

        let gone = Rig()
        _ = gone.cache.lookup(11)
        gone.settle()
        gone.cache.forget(11)
        gone.runWaits()
        check(gone.reads == 1, "an app that quits before its menus are read isn't tried again (\(gone.reads) read)")

        // The real read, of a process that isn't there: nothing to go by, not "no zoom".
        let dead = ZoomMenuCache()
        if case .failed = dead.read(99_998) {
            check(true, "the real read of an app with no menu bar to read comes back as nothing to go by")
        } else {
            check(false, "the real read of an app with no menu bar to read comes back as nothing to go by")
        }
    }
}
