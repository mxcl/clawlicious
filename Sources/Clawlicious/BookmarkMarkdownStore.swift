import Foundation

struct BookmarkMarkdownStore: Sendable {
    var save: @Sendable (Bookmark, String) throws -> Void
    var updateMetadata: @Sendable (Bookmark) throws -> Void
    var delete: @Sendable (Bookmark.ID) throws -> Void
    var directory: @Sendable () throws -> URL

    static let live = at(markdownDirectory)

    static func at(_ directory: @escaping @Sendable () throws -> URL) -> BookmarkMarkdownStore {
        BookmarkMarkdownStore(
            save: { bookmark, markdown in
                let directory = try directory()
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try document(bookmark: bookmark, markdown: markdown)
                    .write(to: fileURL(for: bookmark.id, in: directory), atomically: true, encoding: .utf8)
            },
            updateMetadata: { bookmark in
                let directory = try directory()
                let url = fileURL(for: bookmark.id, in: directory)
                guard FileManager.default.fileExists(atPath: url.path) else { return }
                let markdown = try body(from: String(contentsOf: url, encoding: .utf8))
                try document(bookmark: bookmark, markdown: markdown)
                    .write(to: url, atomically: true, encoding: .utf8)
            },
            delete: { id in
                let url = try fileURL(for: id, in: directory())
                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
            },
            directory: directory
        )
    }
}

private func markdownDirectory() throws -> URL {
    try clawliciousApplicationSupportURL()
        .appending(path: "Agent", directoryHint: .isDirectory)
        .appending(path: "links", directoryHint: .isDirectory)
}

private func fileURL(for id: Bookmark.ID, in directory: URL) -> URL {
    directory.appending(path: "\(id.uuidString).md")
}

private func document(bookmark: Bookmark, markdown: String) -> String {
    """
    ---
    id: \(quoted(bookmark.id.uuidString))
    url: \(quoted(bookmark.url.absoluteString))
    title: \(quoted(bookmark.title))
    domain: \(quoted(bookmark.domain))
    category: \(quoted(bookmark.category))
    \(tagsFrontMatter(bookmark.tags))
    createdAt: \(quoted(JSONEncoder.clawlicious.string(from: bookmark.createdAt)))
    updatedAt: \(quoted(JSONEncoder.clawlicious.string(from: bookmark.updatedAt)))
    status: \(quoted(bookmark.status.rawValue))
    ---

    # \(bookmark.title)

    \(bookmark.summary)

    ## Page Markdown

    \(markdown)
    """
}

private func tagsFrontMatter(_ tags: [String]) -> String {
    if tags.isEmpty {
        return "tags: []"
    }
    return "tags:\n" + tags.map { "- \(quoted($0))" }.joined(separator: "\n")
}

private func body(from document: String) -> String {
    let marker = "\n## Page Markdown\n\n"
    guard let range = document.range(of: marker) else { return "" }
    return String(document[range.upperBound...])
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
