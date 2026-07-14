import Foundation

public struct BookmarkMarkdownStore: Sendable {
    public var save: @Sendable (Bookmark, String) throws -> Void
    public var refresh: @Sendable (Bookmark, String) throws -> Void
    public var updateMetadata: @Sendable (Bookmark) throws -> Void
    public var delete: @Sendable (Bookmark.ID) throws -> Void
    public var directory: @Sendable () throws -> URL

    public init(save: @escaping @Sendable (Bookmark, String) throws -> Void, refresh: @escaping @Sendable (Bookmark, String) throws -> Void, updateMetadata: @escaping @Sendable (Bookmark) throws -> Void, delete: @escaping @Sendable (Bookmark.ID) throws -> Void, directory: @escaping @Sendable () throws -> URL) {
        self.save = save
        self.refresh = refresh
        self.updateMetadata = updateMetadata
        self.delete = delete
        self.directory = directory
    }

    public static let live = at(markdownDirectory)

    public static func at(_ directory: @escaping @Sendable () throws -> URL) -> BookmarkMarkdownStore {
        BookmarkMarkdownStore(
            save: { bookmark, markdown in
                let directory = try directory()
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try document(bookmark: bookmark, markdown: markdown)
                    .write(to: fileURL(for: bookmark.id, in: directory), atomically: true, encoding: .utf8)
            },
            refresh: { bookmark, markdown in
                let directory = try directory()
                let currentURL = fileURL(for: bookmark.id, in: directory)
                guard FileManager.default.fileExists(atPath: currentURL.path) else {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    try document(bookmark: bookmark, markdown: markdown)
                        .write(to: currentURL, atomically: true, encoding: .utf8)
                    return
                }

                let current = try String(contentsOf: currentURL, encoding: .utf8)
                let oldMarkdown = body(from: current)
                guard oldMarkdown != markdown else { return }

                let oldID = markdownID(from: current) ?? bookmark.id.uuidString
                let versions = directory.appending(path: "versions", directoryHint: .isDirectory)
                try FileManager.default.createDirectory(at: versions, withIntermediateDirectories: true)
                try current.write(to: versions.appending(path: "\(oldID).md"), atomically: true, encoding: .utf8)
                try document(
                    bookmark: bookmark,
                    markdown: markdown,
                    markdownID: UUID().uuidString,
                    previous: MarkdownPrevious(
                        id: oldID,
                        path: "versions/\(oldID).md",
                        stats: diffStats(old: oldMarkdown, new: markdown)
                    )
                )
                .write(to: currentURL, atomically: true, encoding: .utf8)
            },
            updateMetadata: { bookmark in
                let directory = try directory()
                let url = fileURL(for: bookmark.id, in: directory)
                guard FileManager.default.fileExists(atPath: url.path) else { return }
                let current = try String(contentsOf: url, encoding: .utf8)
                let markdown = body(from: current)
                try document(
                    bookmark: bookmark,
                    markdown: markdown,
                    markdownID: markdownID(from: current) ?? bookmark.id.uuidString,
                    previous: previous(from: current)
                )
                    .write(to: url, atomically: true, encoding: .utf8)
            },
            delete: { id in
                let directory = try directory()
                let url = fileURL(for: id, in: directory)
                let versions = directory.appending(path: "versions", directoryHint: .isDirectory)
                if let files = try? FileManager.default.contentsOfDirectory(at: versions, includingPropertiesForKeys: nil) {
                    for file in files where (try? frontMatterValue("id", in: String(contentsOf: file, encoding: .utf8))) == id.uuidString {
                        try FileManager.default.removeItem(at: file)
                    }
                }
                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
            },
            directory: directory
        )
    }
}

private func markdownDirectory() throws -> URL {
    try clawliciousStorageURL()
}

private func fileURL(for id: Bookmark.ID, in directory: URL) -> URL {
    directory.appending(path: "\(id.uuidString).md")
}

private func document(
    bookmark: Bookmark,
    markdown: String,
    markdownID: String? = nil,
    previous: MarkdownPrevious? = nil
) -> String {
    """
    ---
    id: \(quoted(bookmark.id.uuidString))
    markdownId: \(quoted(markdownID ?? bookmark.id.uuidString))
    url: \(quoted(bookmark.url.absoluteString))
    title: \(quoted(bookmark.title))
    domain: \(quoted(bookmark.domain))
    category: \(quoted(bookmark.category))
    \(tagsFrontMatter(bookmark.tags))
    createdAt: \(quoted(JSONEncoder.clawlicious.string(from: bookmark.createdAt)))
    updatedAt: \(quoted(JSONEncoder.clawlicious.string(from: bookmark.updatedAt)))
    status: \(quoted(bookmark.status.rawValue))
    \(previousFrontMatter(previous))
    ---

    # \(bookmark.title)

    \(bookmark.summary)

    ## Page Markdown

    \(markdown)
    """
}

private struct MarkdownPrevious {
    var id: String
    var path: String
    var stats: MarkdownDiffStats
}

private struct MarkdownDiffStats {
    var addedLines: Int
    var removedLines: Int
    var changePercent: Int
}

private func tagsFrontMatter(_ tags: [String]) -> String {
    if tags.isEmpty {
        return "tags: []"
    }
    return "tags:\n" + tags.map { "- \(quoted($0))" }.joined(separator: "\n")
}

private func previousFrontMatter(_ previous: MarkdownPrevious?) -> String {
    guard let previous else { return "previousMarkdownId: null" }
    return """
    previousMarkdownId: \(quoted(previous.id))
    previousMarkdownPath: \(quoted(previous.path))
    markdownChangedLines: \(previous.stats.addedLines + previous.stats.removedLines)
    markdownAddedLines: \(previous.stats.addedLines)
    markdownRemovedLines: \(previous.stats.removedLines)
    markdownChangePercent: \(previous.stats.changePercent)
    """
}

private func body(from document: String) -> String {
    let marker = "\n## Page Markdown\n\n"
    guard let range = document.range(of: marker) else { return "" }
    return String(document[range.upperBound...])
}

private func markdownID(from document: String) -> String? {
    frontMatterValue("markdownId", in: document)
}

private func previous(from document: String) -> MarkdownPrevious? {
    guard let id = frontMatterValue("previousMarkdownId", in: document),
          id != "null" else {
        return nil
    }
    return MarkdownPrevious(
        id: id,
        path: frontMatterValue("previousMarkdownPath", in: document) ?? "",
        stats: MarkdownDiffStats(
            addedLines: Int(frontMatterValue("markdownAddedLines", in: document) ?? "") ?? 0,
            removedLines: Int(frontMatterValue("markdownRemovedLines", in: document) ?? "") ?? 0,
            changePercent: Int(frontMatterValue("markdownChangePercent", in: document) ?? "") ?? 0
        )
    )
}

private func frontMatterValue(_ key: String, in document: String) -> String? {
    let prefix = "\(key): "
    guard let line = document.split(separator: "\n").first(where: { $0.hasPrefix(prefix) }) else { return nil }
    let value = line.dropFirst(prefix.count)
    if value.hasPrefix("\""), value.hasSuffix("\""),
       let data = String(value).data(using: .utf8),
       let decoded = try? JSONDecoder().decode(String.self, from: data) {
        return decoded
    }
    return String(value)
}

private func diffStats(old: String, new: String) -> MarkdownDiffStats {
    let oldCounts = lineCounts(old)
    let newCounts = lineCounts(new)
    let removed = oldCounts.reduce(0) { total, item in
        total + max(0, item.value - (newCounts[item.key] ?? 0))
    }
    let added = newCounts.reduce(0) { total, item in
        total + max(0, item.value - (oldCounts[item.key] ?? 0))
    }
    let denominator = max(old.split(separator: "\n", omittingEmptySubsequences: false).count, 1)
    return MarkdownDiffStats(
        addedLines: added,
        removedLines: removed,
        changePercent: Int(((Double(added + removed) / Double(denominator)) * 100).rounded())
    )
}

private func lineCounts(_ value: String) -> [String: Int] {
    value.split(separator: "\n", omittingEmptySubsequences: false).reduce(into: [:]) { counts, line in
        counts[String(line), default: 0] += 1
    }
}

private func quoted(_ value: String) -> String {
    guard let data = try? JSONEncoder().encode(value),
          let string = String(data: data, encoding: .utf8) else {
        return "\"\""
    }
    return string
}

private extension JSONEncoder {
    func string(from date: Date) -> String {
        let data = (try? encode(date)) ?? Data("\"\"".utf8)
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: CharacterSet(charactersIn: "\"")) ?? ""
    }
}
