import Foundation

// Chrome's fonts for web pages that don't pick their own (Settings, Appearance, Customize fonts), in every profile:
// Atkinson Hyperlegible Next for standard, serif and sans-serif text, Mono for fixed-width. They live in each profile's
// Preferences file, which Chrome rewrites from memory while it runs, so the change waits until Chrome is quit.
struct ChromeFont: QuitFirstFont {
    static let keys = ["standard", "serif", "sansserif", "fixed"]

    var id = "chrome"
    let appName = "Chrome"
    let bundleID = "com.google.Chrome"
    var root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Google/Chrome")
    var isRunning: () -> Bool = { AppScript.isRunning("com.google.Chrome") }

    var whatChanges: String {
        let what = "web pages that don't choose their own font"
        if let pending { return "\(what), \(pending ? "on" : "off") once Chrome is quit" }
        return what
    }

    static func font(for key: String) -> String { key == "fixed" ? BundledFont.monoFamily : BundledFont.family }

    var profiles: [URL] {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("Local State")),
              let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cache = (state["profile"] as? [String: Any])?["info_cache"] as? [String: Any] else { return [] }
        return cache.keys.sorted().map { root.appendingPathComponent($0).appendingPathComponent("Preferences") }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    var isApplied: Bool {
        let all = profiles
        return !all.isEmpty && all.allSatisfy { profile in
            let fonts = Self.fonts(in: Self.read(profile) ?? [:])
            return Self.keys.allSatisfy { fonts[$0] == Self.font(for: $0) }
        }
    }

    func apply() throws {
        var before: [String: Any] = [:]
        for profile in profiles {
            guard var prefs = Self.read(profile) else { continue }
            before[profile.path] = Self.fonts(in: prefs)
            Self.setFonts(Dictionary(uniqueKeysWithValues: Self.keys.map { ($0, Self.font(for: $0)) }), removing: [], in: &prefs)
            try Self.write(prefs, to: profile)
        }
        FontTargetMemory.remember(id, before)
    }

    func undo() throws {
        let before = FontTargetMemory.before(id) ?? [:]
        for profile in profiles {
            let old = before[profile.path] as? [String: String] ?? [:]
            guard var prefs = Self.read(profile) else { continue }
            Self.setFonts(old.filter { Self.keys.contains($0.key) }, removing: Self.keys.filter { old[$0] == nil }, in: &prefs)
            try Self.write(prefs, to: profile)
        }
        FontTargetMemory.forget(id)
    }

    // webkit.webprefs.fonts.<key>.Zyyy, Zyyy being the script for text in no particular script, Latin included.
    static func fonts(in prefs: [String: Any]) -> [String: String] {
        let fonts = ((prefs["webkit"] as? [String: Any])?["webprefs"] as? [String: Any])?["fonts"] as? [String: Any] ?? [:]
        return keys.reduce(into: [:]) { $0[$1] = (fonts[$1] as? [String: Any])?["Zyyy"] as? String }
    }

    static func setFonts(_ values: [String: String], removing removed: [String], in prefs: inout [String: Any]) {
        var webkit = prefs["webkit"] as? [String: Any] ?? [:]
        var webprefs = webkit["webprefs"] as? [String: Any] ?? [:]
        var fonts = webprefs["fonts"] as? [String: Any] ?? [:]
        for key in keys where values[key] != nil || removed.contains(key) {
            var scripts = fonts[key] as? [String: Any] ?? [:]
            scripts["Zyyy"] = values[key]
            fonts[key] = scripts.isEmpty ? nil : scripts
        }
        webprefs["fonts"] = fonts.isEmpty ? nil : fonts
        webkit["webprefs"] = webprefs.isEmpty ? nil : webprefs
        prefs["webkit"] = webkit.isEmpty ? nil : webkit
    }

    // nil for a file that isn't readable JSON, which is then left alone.
    static func read(_ file: URL) -> [String: Any]? {
        (try? Data(contentsOf: file)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    // In one step, so Chrome never finds half a file, and with the file's own permissions.
    static func write(_ prefs: [String: Any], to file: URL) throws {
        let permissions = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.posixPermissions]
        try JSONSerialization.data(withJSONObject: prefs, options: [.withoutEscapingSlashes]).write(to: file, options: .atomic)
        if let permissions { try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: file.path) }
    }
}
