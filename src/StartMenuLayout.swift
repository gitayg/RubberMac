import Foundation

struct StartMenuFolder: Codable, Equatable {
    var id: String
    var name: String
    var apps: [String]
}

// One place on the grid: an app, by path, or a folder of them.
enum StartMenuItem: Equatable {
    case app(String)
    case folder(StartMenuFolder)

    var apps: [String] {
        switch self {
        case .app(let path): return [path]
        case .folder(let folder): return folder.apps
        }
    }
}

// Written as {"app": path} or {"folder": {...}}, which reads well in start.json.
extension StartMenuItem: Codable {
    private enum Key: String, CodingKey { case app, folder }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        if let path = try container.decodeIfPresent(String.self, forKey: .app) {
            self = .app(path)
        } else {
            self = .folder(try container.decode(StartMenuFolder.self, forKey: .folder))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        switch self {
        case .app(let path): try container.encode(path, forKey: .app)
        case .folder(let folder): try container.encode(folder, forKey: .folder)
        }
    }
}

// Where a dragged tile comes from.
enum StartMenuPlace: Equatable {
    case pin(Int)
    case main(Int)
    case folder(String, Int)
}

// Where it's dropped: before a position in the pinned row, the grid or a folder, or onto one of the grid's tiles.
enum StartMenuDrop: Equatable {
    case pin(Int)
    case main(Int)
    case onto(Int)
    case folder(String, Int)
}

// The user's own order: the grid of apps and folders, and the pinned row above it, by path.
struct StartMenuLayout: Codable, Equatable {
    static let folderName = "Folder"

    var pins: [String] = []
    var items: [StartMenuItem] = []

    // The grid in order, with each folder's apps where the folder is.
    var allApps: [String] { items.flatMap(\.apps) }

    func folder(_ id: String) -> StartMenuFolder? {
        for case .folder(let folder) in items where folder.id == id { return folder }
        return nil
    }

    private func folderIndex(_ id: String) -> Int? {
        items.firstIndex { if case .folder(let folder) = $0 { folder.id == id } else { false } }
    }

    // Fitted to the apps there are now: apps that are gone go, a folder left with one app becomes that app, and new apps
    // join at the end, in the order given.
    func fitted(to apps: [String]) -> StartMenuLayout {
        let present = Set(apps)
        var fitted = StartMenuLayout()
        var placed = Set<String>()
        func keep(_ path: String) -> Bool { present.contains(path) && placed.insert(path).inserted }
        for item in items {
            switch item {
            case .app(let path):
                if keep(path) { fitted.items.append(.app(path)) }
            case .folder(var folder):
                folder.apps = folder.apps.filter(keep)
                if folder.apps.count > 1 {
                    fitted.items.append(.folder(folder))
                } else if let only = folder.apps.first {
                    fitted.items.append(.app(only))
                }
            }
        }
        fitted.items += apps.filter { placed.insert($0).inserted }.map { .app($0) }
        var pinned = Set<String>()
        fitted.pins = pins.filter { present.contains($0) && pinned.insert($0).inserted }
        return fitted
    }

    func isPinned(_ path: String) -> Bool { pins.contains(path) }

    mutating func pin(_ path: String) {
        if !pins.contains(path) { pins.append(path) }
    }

    mutating func unpin(_ path: String) {
        pins.removeAll { $0 == path }
    }

    mutating func rename(_ id: String, to name: String) {
        guard let index = folderIndex(id), case .folder(var folder) = items[index] else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        folder.name = trimmed.isEmpty ? Self.folderName : trimmed
        items[index] = .folder(folder)
    }

    // Whether a drop would change anything, which is what makes it allowed.
    func allows(_ from: StartMenuPlace, to drop: StartMenuDrop) -> Bool {
        var copy = self
        return copy.move(from, to: drop)
    }

    // Returns false, changing nothing, for a drop that does nothing or isn't allowed: a folder onto a tile (no folders in
    // folders), the pinned row to or from anywhere but itself.
    @discardableResult
    mutating func move(_ from: StartMenuPlace, to drop: StartMenuDrop) -> Bool {
        let before = self
        switch (from, drop) {
        case (.pin(let source), .pin(let target)):
            guard pins.indices.contains(source) else { return false }
            Self.reorder(&pins, from: source, before: target)
        case (.main(let source), .main(let target)):
            guard items.indices.contains(source) else { return false }
            Self.reorder(&items, from: source, before: target)
        case (.main(let source), .onto(let target)):
            guard items.indices.contains(source), items.indices.contains(target), source != target,
                  case .app(let path) = items[source] else { return false }
            combine(path, onto: target)
            items.remove(at: source)
        case (.folder(let id, let source), .folder(let targetID, let target)) where id == targetID:
            guard let index = folderIndex(id), case .folder(var folder) = items[index], folder.apps.indices.contains(source) else { return false }
            Self.reorder(&folder.apps, from: source, before: target)
            items[index] = .folder(folder)
        case (.folder(let id, let source), .main), (.folder(let id, let source), .onto):
            guard let index = folderIndex(id), case .folder(var folder) = items[index], folder.apps.indices.contains(source) else { return false }
            if case .onto(let target) = drop, target == index { return false }
            if case .onto(let target) = drop, !items.indices.contains(target) { return false }
            let path = folder.apps.remove(at: source)
            // Left with one app, the folder becomes that app, in the folder's place; the count of items stays the same.
            items[index] = folder.apps.count == 1 ? .app(folder.apps[0]) : .folder(folder)
            switch drop {
            case .main(let target): items.insert(.app(path), at: min(max(target, 0), items.count))
            case .onto(let target): combine(path, onto: target)
            default: break
            }
        default:
            return false
        }
        return self != before
    }

    // An app dropped onto an app makes a folder of the two in that place; onto a folder, it joins the folder.
    private mutating func combine(_ path: String, onto target: Int) {
        switch items[target] {
        case .app(let other):
            items[target] = .folder(StartMenuFolder(id: UUID().uuidString, name: Self.folderName, apps: [other, path]))
        case .folder(var folder):
            folder.apps.append(path)
            items[target] = .folder(folder)
        }
    }

    // target is a position in the list as it was, before the moving one is taken out.
    private static func reorder<T>(_ list: inout [T], from source: Int, before target: Int) {
        let target = min(max(target, 0), list.count)
        guard target != source, target != source + 1 else { return }
        let moved = list.remove(at: source)
        list.insert(moved, at: target > source ? target - 1 : target)
    }
}

// start.json in RubberMAC's data folder, which keeps the old name.
struct StartMenuStore {
    static let defaultURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/ScreenTools/start.json")

    let url: URL

    // nil when there's none yet, or it can't be read.
    func load() -> StartMenuLayout? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try JSONDecoder().decode(StartMenuLayout.self, from: data)
        } catch {
            log("start: couldn't read \(url.lastPathComponent), starting from A to Z")
            return nil
        }
    }

    func save(_ layout: StartMenuLayout) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(layout).write(to: url, options: .atomic)
    }
}
