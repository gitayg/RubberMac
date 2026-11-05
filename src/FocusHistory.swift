import CoreGraphics

// Windows in the order they last had focus, most recent first, so Alt-Tab can go back to the one used before.
struct FocusHistory {
    private static let limit = 200

    private(set) var ids: [CGWindowID] = []

    init(ids: [CGWindowID] = []) {
        self.ids = Array(ids.prefix(Self.limit))
    }

    mutating func focused(_ id: CGWindowID) {
        guard ids.first != id else { return }
        ids.removeAll { $0 == id }
        ids.insert(id, at: 0)
        if ids.count > Self.limit { ids.removeLast(ids.count - Self.limit) }
    }
}
