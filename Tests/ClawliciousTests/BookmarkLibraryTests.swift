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

        for _ in 0..<20 where library.bookmarks.first?.status != .summarized {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(library.bookmarks.first?.status, .summarized)
        XCTAssertEqual(library.bookmarks.first?.title, "Swift Notes")
    }
}

private struct FailingSummarizer: BookmarkSummarizing {
    func summarize(url: URL) async throws -> BookmarkMetadata {
        XCTFail("Search must stay local and AI-free.")
        return BookmarkMetadata(title: "", summary: "", tags: [], category: "")
    }
}

private struct SuccessfulSummarizer: BookmarkSummarizing {
    func summarize(url: URL) async throws -> BookmarkMetadata {
        BookmarkMetadata(
            title: "Swift Notes",
            summary: "Native bookmark app",
            tags: ["swift", "macos"],
            category: "Development"
        )
    }
}
