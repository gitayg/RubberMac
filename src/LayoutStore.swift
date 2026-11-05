import Foundation

struct LayoutWindow: Codable, Equatable {
    var bundleID: String
    var appName: String
    var title: String
    var index: Int
    var frame: CGRect  // Accessibility space
    var minimized: Bool
}

struct LayoutSnapshot: Codable, Equatable {
    var name: String
    var savedAt: Date
    var windows: [LayoutWindow]
}

// Setup key -> snapshot, kept in memory and written through to one JSON file.
final class LayoutStore {
    static let defaultURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/ScreenTools/layouts.json")

    let url: URL
    private(set) var snapshots: [String: LayoutSnapshot]

    init(url: URL = LayoutStore.defaultURL) {
        self.url = url
        snapshots = (try? Data(contentsOf: url)).flatMap { try? Self.decoder.decode([String: LayoutSnapshot].self, from: $0) } ?? [:]
    }

    // An empty snapshot (screen locked, apps not answering) is never stored, so it can't replace a
    // saved one. Returns false when the snapshot was refused.
    @discardableResult
    func put(_ snapshot: LayoutSnapshot, for key: String) throws -> Bool {
        guard !snapshot.windows.isEmpty else { return false }
        snapshots[key] = snapshot
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.encoder.encode(snapshots).write(to: url, options: .atomic)
        return true
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
