import Foundation

extension FeatureRequest {
    enum Outcome: Equatable {
        case sent(id: String)
        case failed(String)
    }

    // No cookies and no cache, so the request carries nothing about this Mac but its body.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForRequest = 20
        return URLSession(configuration: config)
    }()

    static func request(text: String, email: String, to server: URL) -> URLRequest {
        var request = URLRequest(url: server.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // Otherwise macOS names its CFNetwork and Darwin versions and lists the languages this Mac prefers.
        request.setValue("RubberMAC", forHTTPHeaderField: "User-Agent")
        request.setValue("en", forHTTPHeaderField: "Accept-Language")
        request.httpBody = body(text: text, email: email)
        return request
    }

    // Sends the form and calls back on the main thread.
    static func send(text: String, email: String, to server: URL, done: @escaping (Outcome) -> Void) {
        session.dataTask(with: request(text: text, email: email, to: server)) { data, response, error in
            let result = outcome(status: (response as? HTTPURLResponse)?.statusCode ?? 0, data: data, error: error)
            DispatchQueue.main.async { done(result) }
        }.resume()
    }

    // The server's answer in the form's words. Its own reason is shown where it has one, kept short.
    static func outcome(status: Int, data: Data?, error: Error?) -> Outcome {
        if let error {
            return .failed("Couldn't reach RubberMAC's request server: \(error.localizedDescription)")
        }
        let reply = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        if (200..<300).contains(status), reply?["ok"] as? Bool == true, let id = reply?["id"] as? String {
            return .sent(id: id)
        }
        let reason = (reply?["error"] as? String).map { String($0.prefix(200)) }
        switch status {
        case 429: return .failed(reason ?? "Too many requests just now. Please try again later.")
        case 413: return .failed("That's too long to send. Please shorten it a little.")
        case 400..<500: return .failed("The request server turned it down: \(reason ?? "HTTP \(status)")")
        default: return .failed("The request server isn't answering properly (HTTP \(status)). Please try again later.")
        }
    }
}
