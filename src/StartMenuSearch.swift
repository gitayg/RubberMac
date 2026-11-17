import Foundation

// Start's search: each word typed matches the start of a word in an app's name, so "code" finds Visual Studio Code and
// so does "code vis", ignoring case and accents. A capital inside a word starts one too, so "edit" finds TextEdit.
enum StartMenuSearch {
    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func wordStarts(_ name: String) -> [String.Index] {
        var starts: [String.Index] = []
        var previous: Character?
        for index in name.indices {
            let character = name[index]
            defer { previous = character }
            guard character.isLetter || character.isNumber else { continue }
            guard let previous else { starts.append(index); continue }
            if !(previous.isLetter || previous.isNumber) || (previous.isLowercase && character.isUppercase) { starts.append(index) }
        }
        return starts
    }

    // 0 when the name starts with what's typed, 1 when every typed word starts a word somewhere in it, nil otherwise.
    static func rank(_ name: String, _ query: String) -> Int? {
        let query = fold(query)
        guard !query.isEmpty else { return nil }
        let folded = fold(name)
        if folded.hasPrefix(query) { return 0 }
        let words = wordStarts(name).map { fold(String(name[$0...])) }
        return query.split(separator: " ").allSatisfy { typed in words.contains { $0.hasPrefix(typed) } } ? 1 : nil
    }

    // Names that start with it first, then the rest, each in the given order.
    static func results(_ apps: [StartMenuApp], _ query: String) -> [StartMenuApp] {
        apps.enumerated().compactMap { index, app in rank(app.name, query).map { (rank: $0, index: index, app: app) } }
            .sorted { ($0.rank, $0.index) < ($1.rank, $1.index) }.map(\.app)
    }
}
