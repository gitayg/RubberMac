import Foundation

// A Node server on a free local port for the self-test: the request server itself, or a script that writes down what
// arrives. It prints "listening on <port>" first; everything it prints after is kept.
final class FeatureRequestTestServer {
    let port: Int
    private let process: Process
    private let output: Output

    private final class Output: @unchecked Sendable {
        private let lock = NSLock()
        private var text = ""
        func append(_ data: Data) { lock.withLock { text += String(decoding: data, as: UTF8.self) } }
        var lines: [String] { lock.withLock { text.components(separatedBy: "\n") } }
    }

    var url: URL { URL(string: "http://127.0.0.1:\(port)")! }
    var lines: [String] { output.lines }

    // Launched from Finder the PATH is short, so the usual homes of node are tried first.
    static var node: URL? {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        return (["/opt/homebrew/bin", "/usr/local/bin"] + path.split(separator: ":").map(String.init))
            .map { URL(fileURLWithPath: $0).appendingPathComponent("node") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    init?(arguments: [String], environment: [String: String] = [:]) {
        guard let node = Self.node else { return nil }
        let process = Process()
        process.executableURL = node
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment.merging(["PORT": "0", "HOST": "127.0.0.1"]) { $1 }) { $1 }
        let pipe = Pipe()
        process.standardOutput = pipe
        let output = Output()
        pipe.fileHandleForReading.readabilityHandler = { output.append($0.availableData) }
        guard (try? process.run()) != nil else { return nil }
        var port: Int?
        let deadline = Date().addingTimeInterval(10)
        while port == nil, Date() < deadline, process.isRunning {
            port = output.lines.compactMap { line in line.range(of: "listening on ").flatMap { Int(line[$0.upperBound...]) } }.first
            Thread.sleep(forTimeInterval: 0.05)
        }
        guard let port else {
            process.terminate()
            return nil
        }
        self.process = process
        self.output = output
        self.port = port
    }

    func stop() {
        process.terminate()
        process.waitUntilExit()
    }
}
