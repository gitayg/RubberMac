import Synchronization

// Scrolls RubberMAC's mouse tap has seen. The system's own scroll counter misses some: Logi Options+ posts its wheel's
// events, which aren't counted (measured with an MX Master 3), and neither is a scroll the tap swallows. The ⌘ tap
// compares this count too, so a scroll with ⌘ held keeps its release from opening Start. Bumped on the mouse tap's
// thread, read on the keyboard tap's.
enum ScrollSeen {
    private static let seen = Mutex<UInt32>(0)

    static var count: UInt32 { seen.withLock { $0 } }

    static func note() {
        seen.withLock { $0 &+= 1 }
    }
}
