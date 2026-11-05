import Foundation

// The fix shown like tracked changes: the fixed text, with the words it added marked and the draft's words it
// dropped put back in place, struck out, so a fix that loses a word can't go unnoticed.
enum FixDiff {
    enum Kind { case same, added, removed }

    static func segments(from draft: String, to fixed: String) -> [(text: String, kind: Kind)] {
        let old = tokens(draft), new = tokens(fixed)
        let diff = new.difference(from: old)
        let removed = Set(diff.removals.compactMap { if case .remove(let offset, _, _) = $0 { offset } else { nil } })
        let added = Set(diff.insertions.compactMap { if case .insert(let offset, _, _) = $0 { offset } else { nil } })
        var result: [(text: String, kind: Kind)] = []
        var i = 0, j = 0
        while i < old.count || j < new.count {
            if i < old.count, removed.contains(i) {
                // With a space after it, which is part of the dropped word so leaving it out gives the fixed text back.
                if !isSpace(old[i]) { result.append((old[i] + " ", .removed)) }
                i += 1
            } else if j < new.count, added.contains(j) {
                result.append((new[j], isSpace(new[j]) ? .same : .added))
                j += 1
            } else if j < new.count {
                result.append((new[j], .same))
                i += 1
                j += 1
            } else {
                break
            }
        }
        return result
    }

    private static let word = try! NSRegularExpression(pattern: "\\S+|\\s+")

    private static func tokens(_ text: String) -> [String] {
        let ns = text as NSString
        return word.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
    }

    private static func isSpace(_ token: String) -> Bool { token.allSatisfy(\.isWhitespace) }
}
