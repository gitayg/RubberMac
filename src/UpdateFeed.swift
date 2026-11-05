import Foundation

// Where releases are published, and how to read the newest one: this app's public repo, so no token is needed.
enum UpdateFeed {
    static let latestURL = URL(string: "https://api.github.com/repos/gitayg/RubberMac/releases/latest")!

    struct Release: Equatable {
        let version: String
        let zipURL: URL
        let pageURL: URL
    }

    // GitHub's latest-release JSON (drafts and pre-releases never show up there): tag "v1.11.0", a .zip asset.
    static func parse(_ data: Data) -> Release? {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: URL
        }
        struct Body: Decodable {
            let tag_name: String
            let html_url: URL
            let assets: [Asset]
        }
        guard let body = try? JSONDecoder().decode(Body.self, from: data),
              let zip = body.assets.first(where: { $0.name.hasSuffix(".zip") }) else { return nil }
        let version = body.tag_name.hasPrefix("v") ? String(body.tag_name.dropFirst()) : body.tag_name
        return Release(version: version, zipURL: zip.browser_download_url, pageURL: body.html_url)
    }

    // Part by part as numbers, so 1.10.0 is newer than 1.9.2; missing parts count as 0.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
