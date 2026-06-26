import XCTest
@testable import Clawlicious

final class BookmarkLibraryTests: XCTestCase {
    func testCodexAuthReaderPrefersEnvironmentKey() throws {
        let auth = try CodexAuthReader.read(
            path: URL(fileURLWithPath: "/tmp/missing-auth.json"),
            environment: ["OPENAI_API_KEY": "env-key"]
        )

        XCTAssertEqual(auth, CodexAuth(token: "env-key", source: .environment, scopes: []))
    }

    func testCodexAuthReaderUsesAuthAPIKeyBeforeOAuthToken() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let authURL = directory.appending(path: "auth.json")
        try """
        {
          "auth_mode": "chatgpt",
          "OPENAI_API_KEY": "file-key",
          "tokens": { "access_token": "oauth-token" }
        }
        """.write(to: authURL, atomically: true, encoding: .utf8)

        let auth = try CodexAuthReader.read(path: authURL, environment: [:])

        XCTAssertEqual(auth, CodexAuth(token: "file-key", source: .authAPIKey, scopes: [], authMode: "chatgpt"))
    }

    @MainActor
    func testLocalSearchDoesNotInvokeSummarizer() {
        let bookmark = Bookmark(
            id: UUID(),
            url: URL(string: "https://example.com/swift")!,
            domain: "example.com",
            title: "Swift Notes",
            summary: "Native bookmark app",
            tags: ["swift", "macos"],
            category: "Development",
            createdAt: Date(),
            updatedAt: Date(),
            status: .summarized,
            error: nil
        )
        let library = BookmarkLibrary(
            store: BookmarkStore(
                load: { [bookmark] },
                save: { _ in }
            ),
            summarizer: FailingSummarizer()
        )

        library.searchText = "native"

        XCTAssertEqual(library.visibleBookmarks.map(\.id), [bookmark.id])
    }

    @MainActor
    func testDeletingSelectedBookmarkSavesAndSelectsNextBookmark() {
        let first = testBookmark(title: "First", url: "https://example.com/first")
        let second = testBookmark(title: "Second", url: "https://example.com/second")
        let saved = SavedBookmarks()
        let library = BookmarkLibrary(
            store: BookmarkStore(
                load: { [first, second] },
                save: { saved.value = $0 }
            ),
            summarizer: FailingSummarizer()
        )

        library.deleteBookmark(first.id)

        XCTAssertEqual(library.bookmarks.map(\.id), [second.id])
        XCTAssertEqual(saved.value.map(\.id), [second.id])
        XCTAssertEqual(library.selectedID, second.id)
    }

    @MainActor
    func testAddingBookmarkFromRawStringNormalizesURL() {
        let saved = SavedBookmarks()
        let library = BookmarkLibrary(
            store: BookmarkStore(
                load: { [] },
                save: { saved.value = $0 }
            ),
            summarizer: FailingSummarizer()
        )

        XCTAssertTrue(library.addBookmark("example.com/swift"))

        XCTAssertEqual(library.bookmarks.first?.url.absoluteString, "https://example.com/swift")
        XCTAssertEqual(saved.value.first?.url.absoluteString, "https://example.com/swift")
    }

    func testBrowserBookmarkletRequestRequiresTokenAndExtractsURL() {
        let request = "GET /add?token=good&url=https%3A%2F%2Fexample.com%2Fswift%3Fa%3D1%26b%3D2 HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"

        XCTAssertEqual(
            BrowserBookmarkletServer.importURLString(from: request, expectedToken: "good"),
            "https://example.com/swift?a=1&b=2"
        )
        XCTAssertNil(BrowserBookmarkletServer.importURLString(from: request, expectedToken: "bad"))
    }

    func testAgentSearchAPIRequiresTokenAndFiltersBookmarks() throws {
        var ai = testBookmark(title: "AI Hardware", url: "https://example.com/ai")
        ai.summary = "Accelerator tech notes"
        ai.createdAt = try XCTUnwrap(Calendar.current.date(from: DateComponents(year: 2026, month: 6, day: 18)))
        var old = testBookmark(title: "AI Hardware", url: "https://example.com/old")
        old.summary = "Accelerator tech notes"
        old.createdAt = try XCTUnwrap(Calendar.current.date(from: DateComponents(year: 2026, month: 6, day: 10)))
        let request = "GET /search?token=good&q=AI%20tech&from=2026-06-15&to=2026-06-21 HTTP/1.1\r\n\r\n"

        XCTAssertEqual(
            BrowserBookmarkletServer.apiBookmarks(from: request, expectedToken: "good", bookmarks: [old, ai])?.map(\.id),
            [ai.id]
        )
        XCTAssertNil(BrowserBookmarkletServer.apiBookmarks(from: request, expectedToken: "bad", bookmarks: [ai]))
    }

    func testEmptyBrowserMarkdownIsRejectedBeforeSummarizing() {
        XCTAssertThrowsError(
            try BrowserModel.requireReadableMarkdown(PageSnapshot(title: "Loaded", description: "", markdown: " \n "))
        )
        XCTAssertNoThrow(
            try BrowserModel.requireReadableMarkdown(PageSnapshot(title: "Loaded", description: "", markdown: "Readable page text."))
        )
    }

    @MainActor
    func testSnapshotFromDifferentURLDoesNotSummarizeSelectedBookmark() {
        let bookmark = testBookmark(title: "Pending", url: "https://example.com/current")
        let library = BookmarkLibrary(
            store: BookmarkStore(
                load: {
                    var pending = bookmark
                    pending.status = .pending
                    return [pending]
                },
                save: { _ in }
            ),
            summarizer: SuccessfulSummarizer()
        )

        library.summarizeBookmark(bookmark.id, url: URL(string: "https://example.com/old")!, page: .test)

        XCTAssertEqual(library.bookmarks.first?.status, .pending)
        XCTAssertEqual(library.bookmarks.first?.title, "Pending")
    }

    @MainActor
    func testAddingExistingFailedBookmarkRetriesSummary() async throws {
        let bookmark = Bookmark(
            id: UUID(),
            url: URL(string: "https://example.com/swift")!,
            domain: "example.com",
            title: "example.com",
            summary: "Codex metadata failed.",
            tags: [],
            category: "Uncategorized",
            createdAt: Date(),
            updatedAt: Date(),
            status: .failed,
            error: "bad args"
        )
        let library = BookmarkLibrary(
            store: BookmarkStore(
                load: { [bookmark] },
                save: { _ in }
            ),
            summarizer: SuccessfulSummarizer()
        )

        library.addBookmark(bookmark.url)
        library.summarizeBookmark(bookmark.id, url: bookmark.url, page: .test)

        for _ in 0..<20 where library.bookmarks.first?.status != .summarized {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(library.bookmarks.first?.status, .summarized)
        XCTAssertEqual(library.bookmarks.first?.title, "Swift Notes")
        XCTAssertEqual(library.bookmarks.first?.tags, ["macos", "swift"])
    }

    @MainActor
    func testRetryingSummarizedBookmarkWaitsForBrowserSnapshot() async throws {
        let bookmark = testBookmark(title: "Old", url: "https://example.com/old")
        let library = BookmarkLibrary(
            store: BookmarkStore(
                load: { [bookmark] },
                save: { _ in }
            ),
            summarizer: SuccessfulSummarizer()
        )

        library.retryBookmark(bookmark)

        XCTAssertEqual(library.bookmarks.first?.status, .pending)
        library.summarizeBookmark(bookmark.id, url: bookmark.url, page: .test)

        for _ in 0..<20 where library.bookmarks.first?.status != .summarized {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(library.bookmarks.first?.title, "Swift Notes")
    }

    @MainActor
    func testResummarizingBookmarkUsesProvidedBrowserSnapshot() async throws {
        let bookmark = testBookmark(title: "Old", url: "https://example.com/old")
        let library = BookmarkLibrary(
            store: BookmarkStore(
                load: { [bookmark] },
                save: { _ in }
            ),
            summarizer: SnapshotTitleSummarizer()
        )

        library.resummarizeBookmark(bookmark, page: PageSnapshot(title: "Fresh Browser", description: "", markdown: "# Fresh Browser"))

        for _ in 0..<20 where library.bookmarks.first?.status != .summarized {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(library.bookmarks.first?.title, "Fresh Browser")
    }

    @MainActor
    func testSummaryContentWarningIsSaved() async throws {
        let saved = SavedBookmarks()
        let library = BookmarkLibrary(
            store: BookmarkStore(
                load: { [] },
                save: { saved.value = $0 }
            ),
            summarizer: WarningSummarizer()
        )

        library.addBookmark(URL(string: "https://example.com/paywalled")!)
        library.summarizeBookmark(library.bookmarks[0].id, url: library.bookmarks[0].url, page: .test)

        for _ in 0..<20 where library.bookmarks.first?.contentWarning == nil {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(library.bookmarks.first?.contentWarning, "Could only read the public excerpt.")
        XCTAssertEqual(saved.value.first?.contentWarning, "Could only read the public excerpt.")
    }

    @MainActor
    func testCategoriesAreTitleCased() async throws {
        var bookmark = testBookmark(title: "Old", url: "https://example.com/old")
        bookmark.category = "developer tools"
        let savedBookmark = bookmark
        let library = BookmarkLibrary(
            store: BookmarkStore(
                load: { [savedBookmark] },
                save: { _ in }
            ),
            summarizer: LowercaseCategorySummarizer()
        )

        XCTAssertEqual(library.categories, ["Developer Tools"])
        library.retryBookmark(bookmark)
        library.summarizeBookmark(bookmark.id, url: bookmark.url, page: .test)

        for _ in 0..<20 where library.bookmarks.first?.status != .summarized {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(library.bookmarks.first?.category, "Design Systems")
    }

    @MainActor
    func testTagsAreKebabCased() async throws {
        var bookmark = testBookmark(title: "Old", url: "https://example.com/old")
        bookmark.tags = ["Swift UI", "swift_ui", "macOS!", ""]
        let savedBookmark = bookmark
        let library = BookmarkLibrary(
            store: BookmarkStore(
                load: { [savedBookmark] },
                save: { _ in }
            ),
            summarizer: MixedCaseTagSummarizer()
        )

        XCTAssertEqual(library.tags, ["macos", "swift-ui"])
        library.retryBookmark(bookmark)
        library.summarizeBookmark(bookmark.id, url: bookmark.url, page: .test)

        for _ in 0..<20 where library.bookmarks.first?.status != .summarized {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(library.bookmarks.first?.tags, ["design-systems", "swift-ui"])
    }

    @MainActor
    func testSummarizerReceivesCurrentCategoriesAndTags() async throws {
        var design = testBookmark(title: "Design", url: "https://example.com/design")
        design.category = "Design"
        design.tags = ["design", "swift"]
        var tools = testBookmark(title: "Tools", url: "https://example.com/tools")
        tools.category = "Tools"
        tools.tags = ["macos"]
        let savedBookmarks = [design, tools]
        let summarizer = RecordingSummarizer()
        let library = BookmarkLibrary(
            store: BookmarkStore(
                load: { savedBookmarks },
                save: { _ in }
            ),
            summarizer: summarizer
        )

        library.retryBookmark(design)
        library.summarizeBookmark(design.id, url: design.url, page: .test)

        for _ in 0..<20 where library.bookmarks.first(where: { $0.id == design.id })?.status != .summarized {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(summarizer.context, BookmarkLibraryContext(categories: ["Design", "Tools"], tags: ["design", "macos", "swift"]))
    }
}

private func testBookmark(title: String, url: String) -> Bookmark {
    let url = URL(string: url)!
    return Bookmark(
        id: UUID(),
        url: url,
        domain: url.bookmarkDomain,
        title: title,
        summary: "",
        tags: [],
        category: "Uncategorized",
        createdAt: Date(),
        updatedAt: Date(),
        status: .summarized,
        error: nil
    )
}

private final class SavedBookmarks: @unchecked Sendable {
    var value: [Bookmark] = []
}

private struct FailingSummarizer: BookmarkSummarizing {
    func summarize(url: URL, page: PageSnapshot, context: BookmarkLibraryContext) async throws -> BookmarkMetadata {
        XCTFail("Search must stay local and AI-free.")
        return BookmarkMetadata(title: "", summary: "", tags: [], category: "")
    }
}

private struct SuccessfulSummarizer: BookmarkSummarizing {
    func summarize(url: URL, page: PageSnapshot, context: BookmarkLibraryContext) async throws -> BookmarkMetadata {
        BookmarkMetadata(
            title: "Swift Notes",
            summary: "Native bookmark app",
            tags: ["swift", "macos"],
            category: "Development"
        )
    }
}

private struct SnapshotTitleSummarizer: BookmarkSummarizing {
    func summarize(url: URL, page: PageSnapshot, context: BookmarkLibraryContext) async throws -> BookmarkMetadata {
        BookmarkMetadata(title: page.title, summary: page.markdown, tags: ["browser"], category: "Browser")
    }
}

private struct WarningSummarizer: BookmarkSummarizing {
    func summarize(url: URL, page: PageSnapshot, context: BookmarkLibraryContext) async throws -> BookmarkMetadata {
        BookmarkMetadata(
            title: "Paywalled",
            summary: "Public excerpt",
            tags: ["news", "paywall"],
            category: "News",
            contentWarning: "Could only read the public excerpt."
        )
    }
}

private struct LowercaseCategorySummarizer: BookmarkSummarizing {
    func summarize(url: URL, page: PageSnapshot, context: BookmarkLibraryContext) async throws -> BookmarkMetadata {
        BookmarkMetadata(title: "New", summary: "Summary", tags: [], category: "design systems")
    }
}

private struct MixedCaseTagSummarizer: BookmarkSummarizing {
    func summarize(url: URL, page: PageSnapshot, context: BookmarkLibraryContext) async throws -> BookmarkMetadata {
        BookmarkMetadata(title: "New", summary: "Summary", tags: ["Design Systems", "Swift/UI", ""], category: "Design")
    }
}

private final class RecordingSummarizer: BookmarkSummarizing, @unchecked Sendable {
    var context: BookmarkLibraryContext?

    func summarize(url: URL, page: PageSnapshot, context: BookmarkLibraryContext) async throws -> BookmarkMetadata {
        self.context = context
        return BookmarkMetadata(title: "Recorded", summary: "Recorded", tags: ["recorded"], category: "Recorded")
    }
}

private extension PageSnapshot {
    static let test = PageSnapshot(
        title: "Browser title",
        description: "Browser description",
        markdown: "# Browser markdown"
    )
}
