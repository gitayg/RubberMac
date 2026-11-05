import CoreGraphics

enum LayoutMatcher {
    typealias Entry = (title: String, index: Int)

    // Pairs one app's saved windows with its current ones: exact title first, walking both in index
    // order so duplicate titles pair up in order; then by index among whatever is left on each side.
    // Returns positions into `saved` and `current`.
    static func match(saved: [Entry], current: [Entry]) -> [(saved: Int, current: Int)] {
        var free = current.indices.sorted { current[$0].index < current[$1].index }
        var pairs: [(saved: Int, current: Int)] = []
        var leftover: [Int] = []
        for s in saved.indices.sorted(by: { saved[$0].index < saved[$1].index }) {
            if !saved[s].title.isEmpty, let i = free.firstIndex(where: { current[$0].title == saved[s].title }) {
                pairs.append((s, free.remove(at: i)))
            } else {
                leftover.append(s)
            }
        }
        return pairs + zip(leftover, free).map { (saved: $0, current: $1) }
    }

    // A frame saved on a monitor that is gone now would strand the window off-screen.
    static func isOnScreen(_ frame: CGRect, screens: [CGRect]) -> Bool {
        screens.contains { $0.intersects(frame) }
    }

    static func isSame(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 1 && abs(a.minY - b.minY) < 1 && abs(a.width - b.width) < 1 && abs(a.height - b.height) < 1
    }
}
