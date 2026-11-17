import Foundation

// Bundle ID -> the input source the app was last typed in, in one small JSON file beside the window layouts.
enum InputPerAppStore {
    static let defaultURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/ScreenTools/input-per-app.json")

    static func load(_ url: URL) -> [String: String] {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
    }

    static func save(_ memory: [String: String], to url: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(memory).write(to: url, options: .atomic)
        } catch {
            log("input per app: couldn't save (error \((error as NSError).code))")
        }
    }
}
