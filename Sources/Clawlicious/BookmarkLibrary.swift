import Foundation
import ClawliciousCore

@MainActor
final class BookmarkLibrary: ObservableObject {
    @Published private(set) var bookmarks: [Bookmark] = []
    @Published var selectedID: Bookmark.ID?
    @Published var filter: BookmarkFilter = .all
    @Published var searchText = ""
    @Published var newURLString = ""
    @Published var statusLine = ""

    private let store: BookmarkStore
    private let summarizer: BookmarkSummarizing
    private let markdownStore: BookmarkMarkdownStore
    private let commandClient: BookmarkCommandClient?
    private var completionNotificationIDs = Set<Bookmark.ID>()

    init(
        store: BookmarkStore = .live,
        summarizer: BookmarkSummarizing = CodexBookmarkSummarizer(),
        markdownStore: BookmarkMarkdownStore = .live,
        commandClient: BookmarkCommandClient? = nil
    ) {
        self.store = store
        self.summarizer = summarizer
        self.markdownStore = markdownStore
        self.commandClient = commandClient
        do {
            bookmarks = try store.load().map {
                var bookmark = $0
                bookmark.tags = normalizeTags(bookmark.tags)
                bookmark.category = normalizeCategory(bookmark.category)
                return bookmark
            }
            selectedID = bookmarks.first?.id
        } catch {
            statusLine = error.localizedDescription
        }
    }

    var selectedBookmark: Bookmark? {
        guard let selectedID else { return nil }
        return bookmarks.first { $0.id == selectedID }
    }

    var categories: [String] {
        sortedUnique(bookmarks.map(\.category).filter { !$0.isEmpty })
    }

    var tags: [String] {
        sortedUnique(bookmarks.flatMap(\.tags))
    }

    var visibleCategories: [String] {
        categories.filter { count(for: .category($0)) > 0 }
    }

    var visibleTags: [String] {
        tags.filter { count(for: .tag($0)) > 0 }
    }

    var visibleBookmarks: [Bookmark] {
        bookmarks.filter { matchesFilter($0, filter: filter) }.filter(matchesSearch)
    }

    func count(for filter: BookmarkFilter) -> Int {
        bookmarks.lazy.filter { self.matchesFilter($0, filter: filter) }.filter(self.matchesSearch).count
    }

    func resetFilterIfEmpty() {
        if count(for: filter) == 0 {
            filter = .all
        }
    }

    @discardableResult
    func addBookmark(_ rawValue: String, notifyOnCompletion: Bool = false) -> Bool {
        let raw = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = normalizedBookmarkURL(raw) else {
            statusLine = "Enter a valid URL."
            return false
        }
        addBookmark(url, notifyOnCompletion: notifyOnCompletion)
        return true
    }

    func addBookmark(_ url: URL, notifyOnCompletion: Bool = false) {
        if let commandClient {
            statusLine = "Sending \(url.bookmarkDomain) to the menu helper..."
            Task {
                do {
                    try await commandClient.send(.importURL(url.absoluteString))
                } catch {
                    statusLine = error.localizedDescription
                }
            }
            return
        }
        if let existing = bookmarks.first(where: { $0.url == url }) {
            selectedID = existing.id
            if existing.status == .failed {
                if notifyOnCompletion {
                    completionNotificationIDs.insert(existing.id)
                }
                retryBookmark(existing)
            } else {
                statusLine = "Bookmark already saved."
                if notifyOnCompletion {
                    ClawliciousStatusNotification.post(statusLine)
                }
            }
            return
        }

        let now = Date()
        let bookmark = Bookmark(
            id: UUID(),
            url: url,
            domain: url.bookmarkDomain,
            title: url.bookmarkDomain,
            summary: "Summarizing...",
            tags: [],
            category: "Uncategorized",
            createdAt: now,
            updatedAt: now,
            status: .pending,
            error: nil,
            contentWarning: nil
        )
        bookmarks.insert(bookmark, at: 0)
        selectedID = bookmark.id
        if notifyOnCompletion {
            completionNotificationIDs.insert(bookmark.id)
        }
        save()
        statusLine = "Loading \(url.bookmarkDomain) in browser..."
    }

    func addCompleteBookmark(_ bookmark: Bookmark) {
        if let existing = bookmarks.first(where: { $0.url == bookmark.url }) {
            selectedID = existing.id
            statusLine = "Bookmark already saved."
            return
        }

        var bookmark = bookmark
        bookmark.tags = normalizeTags(bookmark.tags)
        bookmark.category = normalizeCategory(bookmark.category)
        bookmark.status = .summarized
        bookmark.error = nil
        bookmark.contentWarning = bookmark.contentWarning?.cleanedSingleLine.nilIfEmpty
        bookmarks.insert(bookmark, at: 0)
        selectedID = bookmark.id
        save()
        statusLine = "Saved \(bookmark.title)."
    }

    func updateBookmarkMetadata(_ metadata: Bookmark) {
        guard let index = bookmarks.firstIndex(where: { $0.url == metadata.url }) else {
            statusLine = "Bookmark not found."
            return
        }

        bookmarks[index].title = metadata.title
        bookmarks[index].summary = metadata.summary
        bookmarks[index].tags = normalizeTags(metadata.tags)
        bookmarks[index].category = normalizeCategory(metadata.category)
        bookmarks[index].status = .summarized
        bookmarks[index].error = nil
        bookmarks[index].contentWarning = metadata.contentWarning?.cleanedSingleLine.nilIfEmpty
        bookmarks[index].updatedAt = Date()
        selectedID = bookmarks[index].id
        save()
        statusLine = updateMarkdownMetadata(bookmarks[index]) ?? "Updated \(bookmarks[index].title)."
    }

    func retryBookmark(_ bookmark: Bookmark) {
        if let commandClient {
            statusLine = "Retrying \(bookmark.url.bookmarkDomain)..."
            Task {
                do {
                    try await commandClient.send(.retry(bookmark.id))
                } catch {
                    statusLine = error.localizedDescription
                }
            }
            return
        }
        retrySummary(bookmark.id, url: bookmark.url)
    }

    func resummarizeBookmark(_ bookmark: Bookmark) {
        guard let commandClient else { return }
        statusLine = "Resummarizing \(bookmark.url.bookmarkDomain)..."
        Task {
            do {
                try await commandClient.send(.resummarize(bookmark.id))
            } catch {
                statusLine = error.localizedDescription
            }
        }
    }

    func reload(selecting requestedID: Bookmark.ID? = nil) {
        do {
            let loaded = try store.load().map {
                var bookmark = $0
                bookmark.tags = normalizeTags(bookmark.tags)
                bookmark.category = normalizeCategory(bookmark.category)
                return bookmark
            }
            bookmarks = loaded
            if let requestedID, loaded.contains(where: { $0.id == requestedID }) {
                selectedID = requestedID
            } else if let selectedID, !loaded.contains(where: { $0.id == selectedID }) {
                self.selectedID = loaded.first?.id
            } else if selectedID == nil {
                selectedID = loaded.first?.id
            }
            resetFilterIfEmpty()
        } catch {
            statusLine = error.localizedDescription
        }
    }

    func summarizeBookmark(_ id: Bookmark.ID, url: URL, page: PageSnapshot) {
        guard let bookmark = bookmarks.first(where: { $0.id == id }),
              bookmark.url == url,
              bookmark.status == .pending else {
            return
        }
        statusLine = "Invoking Codex for \(url.bookmarkDomain)..."
        Task {
            await summarize(id, url: url, page: page)
        }
    }

    func refreshBookmarkMarkdown(_ id: Bookmark.ID, url: URL, page: PageSnapshot) {
        guard let bookmark = bookmarks.first(where: { $0.id == id }),
              bookmark.url == url else {
            return
        }
        statusLine = refreshMarkdown(bookmark, markdown: page.markdown) ?? statusLine
    }

    func resummarizeBookmark(_ bookmark: Bookmark, page: PageSnapshot) {
        update(bookmark.id) { bookmark in
            bookmark.status = .pending
            bookmark.summary = "Summarizing..."
            bookmark.error = nil
            bookmark.contentWarning = nil
            bookmark.updatedAt = Date()
        }
        save()
        statusLine = "Invoking Codex for \(bookmark.url.bookmarkDomain)..."
        Task {
            await summarize(bookmark.id, url: bookmark.url, page: page)
        }
    }

    func failResummarizeBookmark(_ bookmark: Bookmark, error: Error) {
        update(bookmark.id) { bookmark in
            bookmark.status = .failed
            bookmark.summary = "Browser content failed: \(error.localizedDescription.cleanedSingleLine)"
            bookmark.error = error.localizedDescription
            bookmark.contentWarning = error.localizedDescription.cleanedSingleLine
            bookmark.updatedAt = Date()
        }
        save()
        statusLine = error.localizedDescription
    }

    func failBookmark(_ id: Bookmark.ID, error: Error) {
        guard bookmarks.first(where: { $0.id == id })?.status == .pending else { return }
        update(id) { bookmark in
            bookmark.status = .failed
            bookmark.summary = "Browser content failed: \(error.localizedDescription.cleanedSingleLine)"
            bookmark.error = error.localizedDescription
            bookmark.contentWarning = error.localizedDescription.cleanedSingleLine
            bookmark.updatedAt = Date()
        }
        save()
        statusLine = error.localizedDescription
    }

    func deleteBookmark(_ id: Bookmark.ID) {
        guard let bookmark = bookmarks.first(where: { $0.id == id }) else { return }
        do {
            bookmarks = try store.mutate { bookmarks in
                bookmarks.removeAll { $0.id == id }
            }
        } catch {
            statusLine = error.localizedDescription
            return
        }
        if selectedID == id {
            selectedID = visibleBookmarks.first?.id ?? bookmarks.first?.id
        }
        statusLine = deleteMarkdown(id) ?? "Deleted \(bookmark.title)."
        ClawliciousLibraryNotification.post(bookmarkID: id)
    }

    private func retrySummary(_ id: Bookmark.ID, url: URL) {
        update(id) { bookmark in
            bookmark.status = .pending
            bookmark.summary = "Summarizing..."
            bookmark.error = nil
            bookmark.contentWarning = nil
            bookmark.updatedAt = Date()
        }
        save()
        statusLine = "Reloading \(url.bookmarkDomain) in browser..."
    }

    private func summarize(_ id: Bookmark.ID, url: URL, page: PageSnapshot) async {
        do {
            let metadata = try await summarizer.summarize(url: url, page: page, context: BookmarkLibraryContext(categories: categories, tags: tags))
            update(id) { bookmark in
                bookmark.title = metadata.title.isEmpty ? bookmark.title : metadata.title
                bookmark.summary = metadata.summary
                bookmark.tags = normalizeTags(metadata.tags)
                bookmark.category = normalizeCategory(metadata.category)
                bookmark.status = .summarized
                bookmark.error = nil
                bookmark.contentWarning = metadata.contentWarning?.cleanedSingleLine.nilIfEmpty
                bookmark.updatedAt = Date()
            }
            if let bookmark = bookmarks.first(where: { $0.id == id }) {
                statusLine = saveMarkdown(bookmark, markdown: page.markdown) ?? "Saved metadata for \(url.bookmarkDomain)."
            } else {
                statusLine = "Saved metadata for \(url.bookmarkDomain)."
            }
            postCompletionNotificationIfNeeded(id)
        } catch {
            update(id) { bookmark in
                bookmark.status = .failed
                bookmark.summary = "Codex metadata failed: \(error.localizedDescription.cleanedSingleLine)"
                bookmark.error = error.localizedDescription
                bookmark.contentWarning = error.localizedDescription.cleanedSingleLine
                bookmark.updatedAt = Date()
            }
            statusLine = error.localizedDescription
            postCompletionNotificationIfNeeded(id)
        }
        save()
    }

    private func postCompletionNotificationIfNeeded(_ id: Bookmark.ID) {
        guard completionNotificationIDs.remove(id) != nil else { return }
        ClawliciousStatusNotification.post(statusLine)
    }

    private func saveMarkdown(_ bookmark: Bookmark, markdown: String) -> String? {
        do {
            try markdownStore.save(bookmark, markdown)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func refreshMarkdown(_ bookmark: Bookmark, markdown: String) -> String? {
        do {
            try markdownStore.refresh(bookmark, markdown)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func updateMarkdownMetadata(_ bookmark: Bookmark) -> String? {
        do {
            try markdownStore.updateMetadata(bookmark)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func deleteMarkdown(_ id: Bookmark.ID) -> String? {
        do {
            try markdownStore.delete(id)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func update(_ id: Bookmark.ID, mutate: (inout Bookmark) -> Void) {
        guard let index = bookmarks.firstIndex(where: { $0.id == id }) else { return }
        mutate(&bookmarks[index])
    }

    private func save() {
        do {
            try store.save(bookmarks)
        } catch {
            statusLine = error.localizedDescription
        }
    }

    private func matchesFilter(_ bookmark: Bookmark, filter: BookmarkFilter) -> Bool {
        switch filter {
        case .all:
            true
        case .category(let category):
            bookmark.category == category
        case .tag(let tag):
            bookmark.tags.contains(tag)
        }
    }

    private func matchesSearch(_ bookmark: Bookmark) -> Bool {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        return [
            bookmark.title,
            bookmark.domain,
            bookmark.summary,
            bookmark.category,
            bookmark.tags.joined(separator: " ")
        ].contains { $0.localizedCaseInsensitiveContains(query) }
    }
}
