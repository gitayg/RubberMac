import Foundation

// Firefox's fonts for web pages that don't pick their own, in every profile: Atkinson Hyperlegible Next for serif and
// sans-serif text in Latin script, Mono for monospace. They're user_pref lines in each profile's prefs.js, which
// Firefox reads as it starts and rewrites as it quits, so the change waits until Firefox is quit. Pages keep choosing
// their own fonts: forcing one on every page would also turn some icons into words.
struct FirefoxFont: QuitFirstFont {
    static let keys = ["font.name.serif.x-western", "font.name.sans-serif.x-western", "font.name.monospace.x-western"]

    var id = "firefox"
    let appName = "Firefox"
    let bundleID = "org.mozilla.firefox"
    var root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Firefox")
    var isRunning: () -> Bool = { AppScript.isRunning("org.mozilla.firefox") }

    var whatChanges: String {
        let what = "web pages that don't choose their own font"
        if let pending { return "\(what), \(pending ? "on" : "off") once Firefox is quit" }
        return what
    }

    static func font(for key: String) -> String { key.contains("monospace") ? BundledFont.monoFamily : BundledFont.family }

    // Each [Profile…] Path= in profiles.ini, relative to it or absolute.
    var profiles: [URL] {
        guard let ini = try? String(contentsOf: root.appendingPathComponent("profiles.ini"), encoding: .utf8) else { return [] }
        var paths: [URL] = [], relative = true, path: String?
        func flush() {
            if let path { paths.append(relative ? root.appendingPathComponent(path) : URL(fileURLWithPath: path)) }
            path = nil; relative = true
        }
        for line in ini.components(separatedBy: .newlines).map({ $0.trimmingCharacters(in: .whitespaces) }) {
            if line.hasPrefix("[") { flush(); continue }
            if line.hasPrefix("Path=") { path = String(line.dropFirst(5)) }
            if line == "IsRelative=0" { relative = false }
        }
        flush()
        return paths.map { $0.appendingPathComponent("prefs.js") }.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    var isApplied: Bool {
        let all = profiles
        return !all.isEmpty && all.allSatisfy { file in
            let lines = Self.lines(in: file)
            return Self.keys.allSatisfy { lines[$0] == Self.line($0, Self.font(for: $0)) }
        }
    }

    func apply() throws {
        var before: [String: Any] = [:]
        for file in profiles {
            before[file.path] = Self.lines(in: file)
            try Self.edit(file, set: Dictionary(uniqueKeysWithValues: Self.keys.map { ($0, Self.line($0, Self.font(for: $0))) }))
        }
        FontTargetMemory.remember(id, before)
    }

    func undo() throws {
        let before = FontTargetMemory.before(id) ?? [:]
        for file in profiles {
            let old = before[file.path] as? [String: String] ?? [:]
            try Self.edit(file, set: Dictionary(uniqueKeysWithValues: Self.keys.map { ($0, old[$0]) }))
        }
        FontTargetMemory.forget(id)
    }

    static func line(_ key: String, _ value: String) -> String { "user_pref(\"\(key)\", \"\(value)\");" }

    // The whole user_pref line for each of the keys that's set.
    static func lines(in file: URL) -> [String: String] {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [:] }
        var found: [String: String] = [:]
        for line in text.components(separatedBy: "\n") {
            for key in keys where line.hasPrefix("user_pref(\"\(key)\",") { found[key] = line }
        }
        return found
    }

    // Replaces each key's line, adds it if it's new, or removes it for nil; every other line stays as it was.
    static func edit(_ file: URL, set values: [String: String?]) throws {
        let text = try String(contentsOf: file, encoding: .utf8)
        var lines = text.components(separatedBy: "\n")
        for (key, value) in values {
            let index = lines.firstIndex { $0.hasPrefix("user_pref(\"\(key)\",") }
            switch (index, value) {
            case let (index?, value?): lines[index] = value
            case let (index?, nil): lines.remove(at: index)
            case let (nil, value?):
                let end = lines.last == "" ? lines.count - 1 : lines.count
                lines.insert(value, at: end)
            case (nil, nil): break
            }
        }
        let permissions = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.posixPermissions]
        try lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
        if let permissions { try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: file.path) }
    }
}
