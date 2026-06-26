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
    func summarize(url: URL, page: PageSnapshot) async throws -> BookmarkMetadata {
        XCTFail("Search must stay local and AI-free.")
        return BookmarkMetadata(title: "", summary: "", tags: [], category: "")
    }
}

private struct SuccessfulSummarizer: BookmarkSummarizing {
    func summarize(url: URL, page: PageSnapshot) async throws -> BookmarkMetadata {
        BookmarkMetadata(
            title: "Swift Notes",
            summary: "Native bookmark app",
            tags: ["swift", "macos"],
            category: "Development"
        )
    }
}

private struct WarningSummarizer: BookmarkSummarizing {
    func summarize(url: URL, page: PageSnapshot) async throws -> BookmarkMetadata {
        BookmarkMetadata(
            title: "Paywalled",
            summary: "Public excerpt",
            tags: ["news", "paywall"],
            category: "News",
            contentWarning: "Could only read the public excerpt."
        )
    }
}

private extension PageSnapshot {
    static let test = PageSnapshot(
        title: "Browser title",
        description: "Browser description",
        markdown: "# Browser markdown"
    )
}
