import Foundation
import Network

final class BrowserBookmarkletServer: @unchecked Sendable {
    static let shared = BrowserBookmarkletServer()

    private let port: UInt16 = 45873
    private let queue = DispatchQueue(label: "clawlicious.browser-bookmarklet")
    private let tokenKey = "BrowserBookmarkletToken"
    private var listener: NWListener?

    private init() {}

    var bookmarklet: String {
        let endpoint = "http://127.0.0.1:\(port)/add?token=\(token)&url="
        return "javascript:(()=>{open('\(endpoint)'+encodeURIComponent(location.href),'clawlicious','popup,width=420,height=220')})()"
    }

    var agentConnectionText: String {
        """
        ```md
        Clawlicious is a local app for managing my saved bookmarks.

        Base URL: http://127.0.0.1:\(port)
        Token: \(token)
        All archived bookmarks as markdown: \(agentMarkdownPath)

        Endpoints:
        - GET /bookmarks?token=\(token)
        - GET /search?token=\(token)&q=ai%20tech&from=YYYY-MM-DD&to=YYYY-MM-DD
        - GET /agent/add?token=\(token)&url=https%3A%2F%2Fexample.com&title=Title&summary=Summary&category=AI&tags=ai%2Ctech
        - GET /update?token=\(token)&url=https%3A%2F%2Fexample.com&title=Better%20Title&summary=Better%20Summary&category=AI&tags=ai%2Ctech

        Use /search for questions about saved links. Use /agent/add to save a
        new link only after you have already summarized and tagged it. Use
        /update to edit metadata for an existing saved link. /agent/add and
        /update reject incomplete data: url, title, summary, category, and
        tags are required. Date filters use createdAt.
        ```
        """
    }

    private var agentMarkdownPath: String {
        (try? BookmarkMarkdownStore.live.directory().path(percentEncoded: false)) ?? "~/Library/Application Support/Clawlicious/Agent/links"
    }

    func start() {
        guard listener == nil, let nwPort = NWEndpoint.Port(rawValue: port) else { return }
        do {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(
                host: .ipv4(IPv4Address("127.0.0.1")!),
                port: nwPort
            )
            let listener = try NWListener(using: parameters)
            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection)
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            NotificationCenter.default.post(
                name: .clawliciousBrowserImportStatus,
                object: "Browser bookmarklet server failed: \(error.localizedDescription)"
            )
        }
    }

    private var token: String {
        if let token = UserDefaults.standard.string(forKey: tokenKey) {
            return token
        }
        let token = UUID().uuidString
        UserDefaults.standard.set(token, forKey: tokenKey)
        return token
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, _, _ in
            guard let self, let data, let request = String(data: data, encoding: .utf8) else {
                Self.respond("Bad request.", status: "400 Bad Request", on: connection)
                return
            }

            guard let route = Self.route(from: request) else {
                Self.respond("Bad request.", status: "400 Bad Request", on: connection)
                return
            }
            guard route.query["token"] == self.token else {
                Self.respond("Forbidden.", status: "403 Forbidden", on: connection)
                return
            }

            if ["/add", "/import"].contains(route.path), let urlString = route.query["url"], !urlString.isEmpty {
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .clawliciousImportBookmark, object: urlString)
                }
                Self.respond("Sent to Clawlicious.", on: connection)
            } else if route.path == "/agent/add" {
                guard let bookmark = Self.completeBookmark(route: route) else {
                    Self.respond("Missing complete bookmark data.", status: "400 Bad Request", on: connection)
                    return
                }
                do {
                    let saved = try Self.addCompleteBookmark(bookmark)
                    Self.respond(saved ? "Saved to Clawlicious." : "Bookmark already saved.", on: connection)
                } catch {
                    Self.respond(error.localizedDescription, status: "500 Internal Server Error", on: connection)
                }
            } else if route.path == "/update" {
                guard let bookmark = Self.completeBookmark(route: route) else {
                    Self.respond("Missing complete bookmark data.", status: "400 Bad Request", on: connection)
                    return
                }
                do {
                    guard try Self.updateBookmarkMetadata(bookmark) else {
                        Self.respond("Bookmark not found.", status: "404 Not Found", on: connection)
                        return
                    }
                    Self.respond("Updated Clawlicious metadata.", on: connection)
                } catch {
                    Self.respond(error.localizedDescription, status: "500 Internal Server Error", on: connection)
                }
            } else if ["/bookmarks", "/search"].contains(route.path) {
                do {
                    let bookmarks = try Self.apiBookmarks(route: route, bookmarks: BookmarkStore.live.load())
                    let data = try JSONEncoder.clawlicious.encode(bookmarks)
                    Self.respond(data, contentType: "application/json; charset=utf-8", on: connection)
                } catch {
                    Self.respond(error.localizedDescription, status: "500 Internal Server Error", on: connection)
                }
            } else {
                Self.respond("Not found.", status: "404 Not Found", on: connection)
            }
        }
    }

    static func importURLString(from request: String, expectedToken: String) -> String? {
        guard let route = route(from: request),
              ["/add", "/import"].contains(route.path),
              route.query["token"] == expectedToken,
              let urlString = route.query["url"],
              !urlString.isEmpty else {
            return nil
        }
        return urlString
    }

    static func apiBookmarks(from request: String, expectedToken: String, bookmarks: [Bookmark]) -> [Bookmark]? {
        guard let route = route(from: request),
              ["/bookmarks", "/search"].contains(route.path),
              route.query["token"] == expectedToken else {
            return nil
        }
        return apiBookmarks(route: route, bookmarks: bookmarks)
    }

    static func completeBookmark(from request: String, expectedToken: String) -> Bookmark? {
        guard let route = route(from: request),
              route.path == "/agent/add",
              route.query["token"] == expectedToken else {
            return nil
        }
        return completeBookmark(route: route)
    }

    static func metadataUpdate(from request: String, expectedToken: String, bookmarks: [Bookmark]) -> Bookmark? {
        guard let route = route(from: request),
              route.path == "/update",
              route.query["token"] == expectedToken,
              let bookmark = completeBookmark(route: route),
              bookmarks.contains(where: { $0.url == bookmark.url }) else {
            return nil
        }
        return bookmark
    }

    private static func route(from request: String) -> Route? {
        guard let line = request.components(separatedBy: "\r\n").first else { return nil }
        let parts = line.split(separator: " ", maxSplits: 2)
        guard parts.count == 3, parts[0] == "GET" else { return nil }
        guard let components = URLComponents(string: "http://127.0.0.1\(parts[1])"),
              !components.path.isEmpty else { return nil }
        return Route(
            path: components.path,
            query: Dictionary((components.queryItems ?? []).compactMap { item in
                item.value.map { (item.name, $0.replacingOccurrences(of: "+", with: " ")) }
            }, uniquingKeysWith: { _, new in new })
        )
    }

    @discardableResult
    private static func addCompleteBookmark(_ bookmark: Bookmark) throws -> Bool {
        var bookmarks = try BookmarkStore.live.load()
        guard !bookmarks.contains(where: { $0.url == bookmark.url }) else { return false }
        var bookmark = bookmark
        bookmark.tags = normalizeTags(bookmark.tags)
        bookmark.category = normalizeCategory(bookmark.category)
        bookmark.status = .summarized
        bookmark.error = nil
        bookmark.contentWarning = bookmark.contentWarning?.cleanedSingleLine.nilIfEmpty
        bookmarks.insert(bookmark, at: 0)
        try BookmarkStore.live.save(bookmarks)
        return true
    }

    @discardableResult
    private static func updateBookmarkMetadata(_ metadata: Bookmark) throws -> Bool {
        var bookmarks = try BookmarkStore.live.load()
        guard let index = bookmarks.firstIndex(where: { $0.url == metadata.url }) else { return false }

        bookmarks[index].title = metadata.title
        bookmarks[index].summary = metadata.summary
        bookmarks[index].tags = normalizeTags(metadata.tags)
        bookmarks[index].category = normalizeCategory(metadata.category)
        bookmarks[index].status = .summarized
        bookmarks[index].error = nil
        bookmarks[index].contentWarning = metadata.contentWarning?.cleanedSingleLine.nilIfEmpty
        bookmarks[index].updatedAt = Date()
        try BookmarkStore.live.save(bookmarks)
        try BookmarkMarkdownStore.live.updateMetadata(bookmarks[index])
        return true
    }

    private static func apiBookmarks(route: Route, bookmarks: [Bookmark]) -> [Bookmark] {
        let terms = (route.query["q"] ?? "")
            .split(whereSeparator: \.isWhitespace)
            .map { $0.lowercased() }
        let from = route.query["from"].flatMap(day)
        let to = route.query["to"].flatMap(day).flatMap { Calendar.current.date(byAdding: .day, value: 1, to: $0) }

        return bookmarks
            .filter { bookmark in
                let haystack = [
                    bookmark.title,
                    bookmark.url.absoluteString,
                    bookmark.domain,
                    bookmark.summary,
                    bookmark.category,
                    bookmark.tags.joined(separator: " ")
                ].joined(separator: " ").lowercased()
                let matchesTerms = terms.allSatisfy { haystack.contains($0) }
                let matchesFrom = from.map { bookmark.createdAt >= $0 } ?? true
                let matchesTo = to.map { bookmark.createdAt < $0 } ?? true
                return matchesTerms && matchesFrom && matchesTo
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    private static func completeBookmark(route: Route) -> Bookmark? {
        guard let url = route.query["url"].flatMap(validURL),
              let title = required(route.query["title"]),
              let summary = required(route.query["summary"]),
              let category = required(route.query["category"]) else {
            return nil
        }
        let tags = (route.query["tags"] ?? "")
            .split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !tags.isEmpty else { return nil }

        let now = Date()
        return Bookmark(
            id: UUID(),
            url: url,
            domain: url.bookmarkDomain,
            title: title,
            summary: summary,
            tags: tags,
            category: category,
            createdAt: now,
            updatedAt: now,
            status: .summarized,
            error: nil,
            contentWarning: route.query["contentWarning"]?.cleanedSingleLine.nilIfEmpty
        )
    }

    private static func required(_ value: String?) -> String? {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    private static func validURL(_ value: String) -> URL? {
        guard let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host != nil else {
            return nil
        }
        return url
    }

    private static func day(_ value: String) -> Date? {
        let parts = value.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    private static func respond(_ body: String, status: String = "200 OK", on connection: NWConnection) {
        let html = """
        <!doctype html><meta charset="utf-8"><title>Clawlicious</title><body>\(body)</body>
        """
        respond(Data(html.utf8), status: status, contentType: "text/html; charset=utf-8", on: connection)
    }

    private static func respond(_ data: Data, status: String = "200 OK", contentType: String, on connection: NWConnection) {
        let headers = "HTTP/1.1 \(status)\r\nContent-Type: \(contentType)\r\nContent-Length: \(data.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(headers.utf8) + data, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private struct Route {
        var path: String
        var query: [String: String]
    }
}
