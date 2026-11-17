import Foundation

// When a search opened through Spotlight is over: its window came and went, or never came.
struct SpotlightWatch {
    static let wait: TimeInterval = 3
    let started: Date
    private var seen = false

    init(started: Date) {
        self.started = started
    }

    mutating func ended(open: Bool, now: Date) -> Bool {
        if open { seen = true }
        return !open && (seen || now.timeIntervalSince(started) > Self.wait)
    }
}
