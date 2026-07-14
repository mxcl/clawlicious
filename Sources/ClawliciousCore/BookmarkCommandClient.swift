import Foundation

public struct BookmarkCommandClient: Sendable {
    private var sender: @Sendable (BookmarkServerCommand) async throws -> Void

    public init(send: @escaping @Sendable (BookmarkServerCommand) async throws -> Void) {
        sender = send
    }

    public func send(_ command: BookmarkServerCommand) async throws {
        try await sender(command)
    }

    public static let loopback = BookmarkCommandClient { command in
        let path: String
        let item: URLQueryItem
        switch command {
        case .importURL(let url):
            path = "/import"
            item = URLQueryItem(name: "url", value: url)
        case .retry(let id):
            path = "/retry"
            item = URLQueryItem(name: "id", value: id.uuidString)
        case .resummarize(let id):
            path = "/resummarize"
            item = URLQueryItem(name: "id", value: id.uuidString)
        }

        var components = URLComponents(string: "http://127.0.0.1:45873")!
        components.path = path
        components.queryItems = [
            URLQueryItem(name: "token", value: BrowserBookmarkletServer.shared.token),
            item
        ]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.timeoutInterval = 2

        var lastError: Error?
        for attempt in 0..<15 {
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    throw commandError(String(data: data, encoding: .utf8)?.cleanedSingleLine.nilIfEmpty ?? "Clawlicious helper returned HTTP \(status).")
                }
                return
            } catch {
                lastError = error
                guard error is URLError, attempt < 14 else { throw error }
                try await Task.sleep(for: .milliseconds(100))
            }
        }
        throw lastError ?? commandError("Clawlicious helper is unavailable.")
    }
}

private func commandError(_ message: String) -> NSError {
    NSError(domain: "Clawlicious", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
}
