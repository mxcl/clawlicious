import Foundation

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

    init(
        store: BookmarkStore = .live,
        summarizer: BookmarkSummarizing = CodexBookmarkSummarizer()
    ) {
        self.store = store
        self.summarizer = summarizer
        do {
            bookmarks = try store.load()
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

    var visibleBookmarks: [Bookmark] {
        bookmarks.filter(matchesFilter).filter(matchesSearch)
    }

    func addBookmarkFromField() {
        let raw = newURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = normalizedURL(raw) else {
            statusLine = "Enter a valid URL."
            return
        }
        newURLString = ""
        addBookmark(url)
    }

    func addBookmark(_ url: URL) {
        if let existing = bookmarks.first(where: { $0.url == url }) {
            selectedID = existing.id
            if existing.status == .failed {
                retryBookmark(existing)
            } else {
                statusLine = "Bookmark already saved."
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
        save()
        statusLine = "Invoking Codex for \(url.bookmarkDomain)..."

        Task {
            await summarize(bookmark.id, url: url)
        }
    }

    func retryBookmark(_ bookmark: Bookmark) {
        retrySummary(bookmark.id, url: bookmark.url)
    }

    func deleteBookmark(_ id: Bookmark.ID) {
        guard let index = bookmarks.firstIndex(where: { $0.id == id }) else { return }
        let bookmark = bookmarks.remove(at: index)
        if selectedID == id {
            selectedID = visibleBookmarks.first?.id ?? bookmarks.first?.id
        }
        save()
        statusLine = "Deleted \(bookmark.title)."
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
        statusLine = "Retrying Codex for \(url.bookmarkDomain)..."
        Task {
            await summarize(id, url: url)
        }
    }

    private func summarize(_ id: Bookmark.ID, url: URL) async {
        do {
            let metadata = try await summarizer.summarize(url: url)
            update(id) { bookmark in
                bookmark.title = metadata.title.isEmpty ? bookmark.title : metadata.title
                bookmark.summary = metadata.summary
                bookmark.tags = sortedUnique(metadata.tags.map(normalizeTag).filter { !$0.isEmpty })
                bookmark.category = metadata.category.isEmpty ? "Uncategorized" : metadata.category
                bookmark.status = .summarized
                bookmark.error = nil
                bookmark.contentWarning = metadata.contentWarning?.cleanedSingleLine.nilIfEmpty
                bookmark.updatedAt = Date()
            }
            statusLine = "Saved metadata for \(url.bookmarkDomain)."
        } catch {
            update(id) { bookmark in
                bookmark.status = .failed
                bookmark.summary = "Codex metadata failed: \(error.localizedDescription.cleanedSingleLine)"
                bookmark.error = error.localizedDescription
                bookmark.contentWarning = error.localizedDescription.cleanedSingleLine
                bookmark.updatedAt = Date()
            }
            statusLine = error.localizedDescription
        }
        save()
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

    private func matchesFilter(_ bookmark: Bookmark) -> Bool {
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

private func normalizedURL(_ raw: String) -> URL? {
    guard !raw.isEmpty else { return nil }
    let candidate = raw.contains("://") ? raw : "https://\(raw)"
    guard let url = URL(string: candidate), let scheme = url.scheme?.lowercased(),
          ["http", "https"].contains(scheme), url.host != nil else {
        return nil
    }
    return url
}

private func normalizeTag(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines)
        .replacing(/\s+/, with: "-")
        .lowercased()
}

func sortedUnique(_ values: [String]) -> [String] {
    Array(Set(values)).sorted {
        $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
    }
}
