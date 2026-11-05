import Foundation

// One reply sent from the writing pad, with the text of the window it answered.
struct SavedReply: Codable, Equatable {
    let date: Date
    let app: String
    let bundleID: String?
    let screen: String
    let typed: String
    let sent: String
}

// Every reply sent from the writing pad, one JSON object per line, in a file per month. Readable only by the user.
enum ReplyStore {
    static let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Screen Tools/Replies", isDirectory: true)

    static func save(_ reply: SavedReply, in folder: URL = folder) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let file = folder.appendingPathComponent("\(month(of: reply.date)).jsonl")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var line = try encoder.encode(reply)
        line.append(0x0A)
        guard let handle = try? FileHandle(forWritingTo: file) else {
            try line.write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            return
        }
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
    }

    static func load(from file: URL) throws -> [SavedReply] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
            .map { try decoder.decode(SavedReply.self, from: Data($0.utf8)) }
    }

    static func month(of date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", parts.year!, parts.month!)
    }
}
