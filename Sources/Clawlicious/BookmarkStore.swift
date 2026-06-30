import Foundation

struct BookmarkStore: Sendable {
    var load: @Sendable () throws -> [Bookmark]
    var save: @Sendable ([Bookmark]) throws -> Void

    static let live = at({ try bookmarksURL() }, seedOnMissing: true)

    static func at(_ storageURL: @escaping @Sendable () throws -> URL, seedOnMissing: Bool = false) -> BookmarkStore {
        BookmarkStore(
            load: {
                let url = try storageURL()
                guard FileManager.default.fileExists(atPath: url.path) else {
                    let bookmarks = seedOnMissing ? onboardingBookmarks : []
                    if seedOnMissing {
                        try persist(bookmarks, to: url)
                    }
                    return bookmarks
                }
                let data = try Data(contentsOf: url)
                var bookmarks = try JSONDecoder.clawlicious.decode([Bookmark].self, from: data)
                if repairDuplicateIDs(&bookmarks) {
                    try persist(bookmarks, to: url)
                }
                return bookmarks
            },
            save: { bookmarks in
                try persist(bookmarks, to: storageURL())
            }
        )
    }
}

func clawliciousStorageURL() throws -> URL {
    let base = try FileManager.default.url(
        for: .documentDirectory,
        in: .userDomainMask,
        appropriateFor: nil,
        create: true
    )
    let url = base.appending(path: "Clawlicious", directoryHint: .isDirectory)
    try migrateLegacyStorage(to: url)
    return url
}

private func bookmarksURL() throws -> URL {
    try clawliciousStorageURL().appending(path: "bookmarks.json")
}

func migrateLegacyStorage(to newDirectory: URL) throws {
    guard let oldDirectory = try? legacyApplicationSupportURL() else { return }
    try migrateLegacyStorage(from: oldDirectory, to: newDirectory)
}

func migrateLegacyStorage(from oldDirectory: URL, to newDirectory: URL) throws {
    guard FileManager.default.fileExists(atPath: oldDirectory.path) else { return }
    try FileManager.default.createDirectory(at: newDirectory, withIntermediateDirectories: true)

    try copyIfMissing(oldDirectory.appending(path: "bookmarks.json"), to: newDirectory.appending(path: "bookmarks.json"))

    let oldLinks = oldDirectory
        .appending(path: "Agent", directoryHint: .isDirectory)
        .appending(path: "links", directoryHint: .isDirectory)
    if let files = try? FileManager.default.contentsOfDirectory(at: oldLinks, includingPropertiesForKeys: nil) {
        for file in files {
            try copyIfMissing(file, to: newDirectory.appending(path: file.lastPathComponent))
        }
    }
}

private func legacyApplicationSupportURL() throws -> URL {
    let base = try FileManager.default.url(
        for: .applicationSupportDirectory,
        in: .userDomainMask,
        appropriateFor: nil,
        create: false
    )
    return base.appending(path: "Clawlicious", directoryHint: .isDirectory)
}

private func copyIfMissing(_ source: URL, to destination: URL) throws {
    guard FileManager.default.fileExists(atPath: source.path),
          !FileManager.default.fileExists(atPath: destination.path) else {
        return
    }
    try FileManager.default.copyItem(at: source, to: destination)
}

private func persist(_ bookmarks: [Bookmark], to url: URL) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    let data = try JSONEncoder.clawlicious.encode(bookmarks)
    try data.write(to: url, options: [.atomic])
}

private func repairDuplicateIDs(_ bookmarks: inout [Bookmark]) -> Bool {
    var ids = Set<Bookmark.ID>()
    var repaired = false

    for index in bookmarks.indices where !ids.insert(bookmarks[index].id).inserted {
        bookmarks[index].id = UUID()
        repaired = true
    }

    return repaired
}

private let onboardingBookmarks: [Bookmark] = {
    let date = Date(timeIntervalSince1970: 1_782_432_000)
    return [
        onboardingBookmark(
            id: "A7F25E5D-23C2-46A1-9026-C703DC2A8A51",
            path: "welcome-overview",
            title: "Welcome & Overview",
            summary: "Start here for what Clawlicious does and the requirement to have Codex CLI or the Codex app installed.",
            tags: ["setup", "codex"],
            date: date
        ),
        onboardingBookmark(
            id: "9CB77F48-8E21-431C-A47A-8E7E13F48A41",
            path: "adding-bookmarks",
            title: "Adding Bookmarks",
            summary: "Save links from the URL field, the Command-Control-Option-B browser shortcut, or the browser bookmarklet copied from the Bookmark menu.",
            tags: ["bookmarks", "bookmarklet"],
            date: date
        ),
        onboardingBookmark(
            id: "23E1E260-F803-4D7F-B3E9-84D3E381E101",
            path: "bringing-your-agent",
            title: "Bringing Your Agent",
            summary: "Connect another agent to Clawlicious for advanced saved-link search, import, and metadata updates.",
            tags: ["agent", "advanced"],
            date: date
        )
    ]
}()

private func onboardingBookmark(id: String, path: String, title: String, summary: String, tags: [String], date: Date) -> Bookmark {
    let url = URL(string: "https://clawlicious.app/docs/\(path)")!
    return Bookmark(
        id: UUID(uuidString: id)!,
        url: url,
        domain: url.bookmarkDomain,
        title: title,
        summary: summary,
        tags: tags,
        category: "Onboarding",
        createdAt: date,
        updatedAt: date,
        status: .summarized,
        error: nil
    )
}

extension JSONDecoder {
    static let clawlicious: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

extension JSONEncoder {
    static let clawlicious: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()
}
