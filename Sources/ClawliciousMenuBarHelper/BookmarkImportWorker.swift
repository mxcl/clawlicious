import ClawliciousCore
import Foundation
import WebKit

@MainActor
final class BookmarkImportWorker {
    typealias PageLoader = @MainActor @Sendable (URL) async throws -> PageSnapshot

    static let shared = BookmarkImportWorker(pageLoader: HiddenPageLoader().load)

    private let store: BookmarkStore
    private let markdownStore: BookmarkMarkdownStore
    private let summarizer: any BookmarkSummarizing
    private let pageLoader: PageLoader
    private let statusHandler: @MainActor @Sendable (String) -> Void
    private var queue: [BookmarkServerCommand] = []
    private var isProcessing = false

    init(
        store: BookmarkStore = .live,
        markdownStore: BookmarkMarkdownStore = .live,
        summarizer: any BookmarkSummarizing = CodexBookmarkSummarizer(),
        pageLoader: @escaping PageLoader,
        statusHandler: @escaping @MainActor @Sendable (String) -> Void = { HelperStatus.shared.show($0) }
    ) {
        self.store = store
        self.markdownStore = markdownStore
        self.summarizer = summarizer
        self.pageLoader = pageLoader
        self.statusHandler = statusHandler
    }

    func enqueue(_ command: BookmarkServerCommand) {
        queue.append(command)
        guard !isProcessing else { return }
        isProcessing = true
        Task { await drain() }
    }

    private func drain() async {
        while !queue.isEmpty {
            await process(queue.removeFirst())
        }
        isProcessing = false
    }

    private func process(_ command: BookmarkServerCommand) async {
        do {
            guard let bookmark = try prepare(command) else { return }
            show("Summarizing \(bookmark.url.bookmarkDomain)...")
            let page = try PageExtraction.requireReadableMarkdown(await pageLoader(bookmark.url))
            let current = try store.load()
            let metadata = try await summarizer.summarize(
                url: bookmark.url,
                page: page,
                context: BookmarkLibraryContext(
                    categories: sortedUnique(current.map(\.category).filter { !$0.isEmpty }),
                    tags: sortedUnique(current.flatMap(\.tags))
                )
            )
            let saved = try complete(bookmark, metadata: metadata)
            try markdownStore.save(saved, page.markdown)
            changed(saved)
            show("Saved \(saved.title).")
        } catch {
            fail(command, error: error)
            show(error.localizedDescription)
        }
    }

    private func prepare(_ command: BookmarkServerCommand) throws -> Bookmark? {
        switch command {
        case .importURL(let rawValue):
            guard let url = normalizedBookmarkURL(rawValue.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                throw workerError("Enter a valid URL.")
            }
            let candidate = pendingBookmark(url)
            let bookmarks = try store.mutate { bookmarks in
                if let index = bookmarks.firstIndex(where: { $0.url == url }) {
                    guard bookmarks[index].status == .failed else { return }
                    markPending(&bookmarks[index])
                } else {
                    bookmarks.insert(candidate, at: 0)
                }
            }
            guard let bookmark = bookmarks.first(where: { $0.url == url }) else { return nil }
            guard bookmark.status == .pending else {
                show("Bookmark already saved.")
                return nil
            }
            changed(bookmark)
            return bookmark

        case .retry(let id), .resummarize(let id):
            let bookmarks = try store.mutate { bookmarks in
                guard let index = bookmarks.firstIndex(where: { $0.id == id }) else { return }
                markPending(&bookmarks[index])
            }
            guard let bookmark = bookmarks.first(where: { $0.id == id }) else {
                throw workerError("Bookmark not found.")
            }
            changed(bookmark)
            return bookmark
        }
    }

    private func complete(_ requested: Bookmark, metadata: BookmarkMetadata) throws -> Bookmark {
        let bookmarks = try store.mutate { bookmarks in
            guard let index = bookmarks.firstIndex(where: { $0.id == requested.id && $0.url == requested.url }),
                  bookmarks[index].status == .pending else { return }
            bookmarks[index].title = metadata.title.isEmpty ? bookmarks[index].title : metadata.title
            bookmarks[index].summary = metadata.summary
            bookmarks[index].tags = normalizeTags(metadata.tags)
            bookmarks[index].category = normalizeCategory(metadata.category)
            bookmarks[index].status = .summarized
            bookmarks[index].error = nil
            bookmarks[index].contentWarning = metadata.contentWarning?.cleanedSingleLine.nilIfEmpty
            bookmarks[index].updatedAt = Date()
        }
        guard let bookmark = bookmarks.first(where: { $0.id == requested.id }), bookmark.status == .summarized else {
            throw workerError("Bookmark changed before summarization completed.")
        }
        return bookmark
    }

    private func fail(_ command: BookmarkServerCommand, error: Error) {
        let id: Bookmark.ID?
        switch command {
        case .importURL(let rawValue):
            id = normalizedBookmarkURL(rawValue.trimmingCharacters(in: .whitespacesAndNewlines))
                .flatMap { url in try? store.load().first(where: { $0.url == url })?.id }
        case .retry(let bookmarkID), .resummarize(let bookmarkID):
            id = bookmarkID
        }
        guard let id,
              let bookmarks = try? store.mutate({ bookmarks in
                  guard let index = bookmarks.firstIndex(where: { $0.id == id && $0.status == .pending }) else { return }
                  bookmarks[index].status = .failed
                  bookmarks[index].summary = "Summarization failed: \(error.localizedDescription.cleanedSingleLine)"
                  bookmarks[index].error = error.localizedDescription
                  bookmarks[index].contentWarning = error.localizedDescription.cleanedSingleLine
                  bookmarks[index].updatedAt = Date()
              }),
              let bookmark = bookmarks.first(where: { $0.id == id }) else { return }
        changed(bookmark)
    }

    private func pendingBookmark(_ url: URL) -> Bookmark {
        let now = Date()
        return Bookmark(
            id: UUID(), url: url, domain: url.bookmarkDomain, title: url.bookmarkDomain,
            summary: "Summarizing...", tags: [], category: "Uncategorized",
            createdAt: now, updatedAt: now, status: .pending, error: nil
        )
    }

    private func changed(_ bookmark: Bookmark) {
        ClawliciousLibraryNotification.post(bookmarkID: bookmark.id, status: bookmark.status)
    }

    private func show(_ message: String) {
        statusHandler(message)
        ClawliciousStatusNotification.post(message)
    }
}

private func markPending(_ bookmark: inout Bookmark) {
    bookmark.status = .pending
    bookmark.summary = "Summarizing..."
    bookmark.error = nil
    bookmark.contentWarning = nil
    bookmark.updatedAt = Date()
}

private func workerError(_ message: String) -> NSError {
    NSError(domain: "Clawlicious", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
}

@MainActor
private final class HiddenPageLoader: NSObject, WKNavigationDelegate {
    private let webView: WKWebView
    private var continuation: CheckedContinuation<PageSnapshot, any Error>?
    private var timeoutTask: Task<Void, Never>?

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
    }

    func load(_ url: URL) async throws -> PageSnapshot {
        guard continuation == nil else { throw workerError("Browser worker is busy.") }
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            webView.load(URLRequest(url: url))
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { return }
                self?.finish(.failure(workerError("Page loading timed out.")))
            }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task {
            do {
                var previous = ""
                var stableReadableCount = 0
                for attempt in 0..<20 {
                    let snapshot = try await snapshot()
                    let text = PageExtraction.clean(snapshot.markdown)
                    if text.count >= 80, PageExtraction.isReadable(snapshot) {
                        stableReadableCount = text == previous ? stableReadableCount + 1 : 0
                        if stableReadableCount >= 2 {
                            finish(.success(snapshot))
                            return
                        }
                    }
                    if attempt == 19 {
                        finish(.success(snapshot))
                        return
                    }
                    previous = text
                    try await Task.sleep(for: .milliseconds(500))
                }
            } catch {
                finish(.failure(error))
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        finish(.failure(error))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        finish(.failure(error))
    }

    private func snapshot() async throws -> PageSnapshot {
        guard let result = try await webView.evaluateJavaScript(PageExtraction.markdownSnapshotScript) as? [String: Any] else {
            throw workerError("Could not read browser page content.")
        }
        return PageSnapshot(
            title: result["title"] as? String ?? webView.url?.bookmarkDomain ?? "Untitled",
            description: result["description"] as? String ?? "",
            markdown: result["markdown"] as? String ?? ""
        )
    }

    private func finish(_ result: Result<PageSnapshot, any Error>) {
        guard let continuation else { return }
        self.continuation = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        webView.stopLoading()
        continuation.resume(with: result)
    }
}
