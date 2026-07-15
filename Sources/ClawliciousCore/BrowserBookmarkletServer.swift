import Foundation
import Network

public enum BookmarkServerCommand: Sendable, Hashable {
    case importURL(String)
    case retry(Bookmark.ID)
    case resummarize(Bookmark.ID)
}

public final class BrowserBookmarkletServer: @unchecked Sendable {
    public static let shared = BrowserBookmarkletServer()

    private let port: UInt16 = 45873
    private let queue = DispatchQueue(label: "clawlicious.browser-bookmarklet")
    private let tokenKey = "BrowserBookmarkletToken"
    private var listener: NWListener?
    private var commandHandler: (@Sendable (BookmarkServerCommand) -> Void)?

    private init() {}

    public var bookmarklet: String {
        let endpoint = "http://127.0.0.1:\(port)/add?token=\(token)&url="
        return "javascript:(()=>{open('\(endpoint)'+encodeURIComponent(location.href),'clawlicious','popup,width=420,height=220')})()"
    }

    public func agentConnectionText(selectedBookmark: Bookmark?) -> String {
        let selection = selectedBookmark.map {
            "Currently selected bookmark: \($0.title.cleanedSingleLine) (\($0.url.absoluteString))\n"
        } ?? ""

        return """
        ```md
        Clawlicious is a local app for managing my saved bookmarks.
        Use this as a plain chat; no project/workspace is needed.
        \(selection)

        Base URL: http://127.0.0.1:\(port)
        Token: \(token)
        All archived bookmarks as markdown: \(agentMarkdownPath)

        Endpoints:
        - GET /bookmarks?token=\(token)
        - GET /search?token=\(token)&q=ai%20tech&from=YYYY-MM-DD&to=YYYY-MM-DD
        - POST /agent/add?token=\(token)
          Body: url=https%3A%2F%2Fexample.com&title=Title&summary=Summary&category=AI&tags=ai%2Ctech
        - POST /update?token=\(token)
          Body: url=https%3A%2F%2Fexample.com&title=Better%20Title&summary=Better%20Summary&category=AI&tags=ai%2Ctech

        Use /search for questions about saved links. Use /agent/add to save a
        new link only after you have already summarized and tagged it. Use
        /update to edit metadata for an existing saved link. /agent/add and
        /update reject incomplete data: url, title, summary, category, and
        tags are required. Date filters use createdAt.
        ```
        """
    }

    private var agentMarkdownPath: String {
        (try? BookmarkMarkdownStore.live.directory().path(percentEncoded: false)) ?? "~/Documents/Clawlicious"
    }

    public func start(commandHandler: @escaping @Sendable (BookmarkServerCommand) -> Void) {
        self.commandHandler = commandHandler
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
            ClawliciousStatusNotification.post("Browser bookmarklet server failed: \(error.localizedDescription)")
        }
    }

    public var token: String {
        let defaults = UserDefaults(suiteName: "dev.mxcl.clawlicious") ?? .standard
        if let token = defaults.string(forKey: tokenKey) {
            return token
        }
        let token = UUID().uuidString
        defaults.set(token, forKey: tokenKey)
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
                guard let commandHandler else {
                    Self.respond("Clawlicious helper is unavailable.", status: "503 Service Unavailable", on: connection)
                    return
                }
                commandHandler(.importURL(urlString))
                Self.respond("Queued in Clawlicious.", status: "202 Accepted", on: connection)
            } else if ["/retry", "/resummarize"].contains(route.path),
                      let id = route.query["id"].flatMap(UUID.init(uuidString:)),
                      let commandHandler {
                commandHandler(route.path == "/retry" ? .retry(id) : .resummarize(id))
                Self.respond("Queued in Clawlicious.", status: "202 Accepted", on: connection)
            } else if route.path == "/agent/add" {
                guard let bookmark = Self.completeBookmark(route: route) else {
                    Self.respond("Missing complete bookmark data.", status: "400 Bad Request", on: connection)
                    return
                }
                do {
                    let saved = try Self.addCompleteBookmark(bookmark)
                    if saved {
                        ClawliciousLibraryNotification.post(bookmarkID: bookmark.id, status: .summarized)
                    }
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
                    if let saved = try? BookmarkStore.live.load().first(where: { $0.url == bookmark.url }) {
                        ClawliciousLibraryNotification.post(bookmarkID: saved.id, status: .summarized)
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

    public static func importURLString(from request: String, expectedToken: String) -> String? {
        guard let route = route(from: request),
              ["/add", "/import"].contains(route.path),
              route.query["token"] == expectedToken,
              let urlString = route.query["url"],
              !urlString.isEmpty else {
            return nil
        }
        return urlString
    }

    public static func apiBookmarks(from request: String, expectedToken: String, bookmarks: [Bookmark]) -> [Bookmark]? {
        guard let route = route(from: request),
              ["/bookmarks", "/search"].contains(route.path),
              route.query["token"] == expectedToken else {
            return nil
        }
        return apiBookmarks(route: route, bookmarks: bookmarks)
    }

    public static func completeBookmark(from request: String, expectedToken: String) -> Bookmark? {
        guard let route = route(from: request),
              route.path == "/agent/add",
              route.query["token"] == expectedToken else {
            return nil
        }
        return completeBookmark(route: route)
    }

    public static func metadataUpdate(from request: String, expectedToken: String, bookmarks: [Bookmark]) -> Bookmark? {
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
        guard parts.count == 3, ["GET", "POST"].contains(parts[0]) else { return nil }
        guard let components = URLComponents(string: "http://127.0.0.1\(parts[1])"),
              !components.path.isEmpty else { return nil }
        var query = fields(from: components.queryItems ?? [])
        if parts[0] == "POST", let body = request.components(separatedBy: "\r\n\r\n").dropFirst().first {
            query.merge(fields(fromFormBody: body), uniquingKeysWith: { _, new in new })
        }
        return Route(
            path: components.path,
            query: query
        )
    }

    private static func fields(from queryItems: [URLQueryItem]) -> [String: String] {
        Dictionary(queryItems.compactMap { item in
            item.value.map { (item.name, $0.replacingOccurrences(of: "+", with: " ")) }
        }, uniquingKeysWith: { _, new in new })
    }

    private static func fields(fromFormBody body: String) -> [String: String] {
        guard let components = URLComponents(string: "http://127.0.0.1?\(body)") else { return [:] }
        return fields(from: components.queryItems ?? [])
    }

    @discardableResult
    private static func addCompleteBookmark(_ bookmark: Bookmark) throws -> Bool {
        var bookmark = bookmark
        bookmark.tags = normalizeTags(bookmark.tags)
        bookmark.category = normalizeCategory(bookmark.category)
        bookmark.status = .summarized
        bookmark.error = nil
        bookmark.contentWarning = bookmark.contentWarning?.cleanedSingleLine.nilIfEmpty
        let prepared = bookmark
        let bookmarks = try BookmarkStore.live.mutate { bookmarks in
            guard !bookmarks.contains(where: { $0.url == prepared.url }) else { return }
            bookmarks.insert(prepared, at: 0)
        }
        return bookmarks.contains(where: { $0.id == prepared.id })
    }

    @discardableResult
    private static func updateBookmarkMetadata(_ metadata: Bookmark) throws -> Bool {
        let bookmarks = try BookmarkStore.live.mutate { bookmarks in
            guard let index = bookmarks.firstIndex(where: { $0.url == metadata.url }) else { return }
            bookmarks[index].title = metadata.title
            bookmarks[index].summary = metadata.summary
            bookmarks[index].tags = normalizeTags(metadata.tags)
            bookmarks[index].category = normalizeCategory(metadata.category)
            bookmarks[index].status = .summarized
            bookmarks[index].error = nil
            bookmarks[index].contentWarning = metadata.contentWarning?.cleanedSingleLine.nilIfEmpty
            bookmarks[index].updatedAt = Date()
        }
        guard let bookmark = bookmarks.first(where: { $0.url == metadata.url }) else { return false }
        try BookmarkMarkdownStore.live.updateMetadata(bookmark)
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
