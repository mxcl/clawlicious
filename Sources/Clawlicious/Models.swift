import Foundation

struct Bookmark: Identifiable, Codable, Hashable, Sendable {
    enum Status: String, Codable {
        case pending
        case summarized
        case failed
    }

    var id: UUID
    var url: URL
    var domain: String
    var title: String
    var summary: String
    var tags: [String]
    var category: String
    var createdAt: Date
    var updatedAt: Date
    var status: Status
    var error: String?
}

struct BookmarkMetadata: Codable, Equatable, Sendable {
    var title: String
    var summary: String
    var tags: [String]
    var category: String
}

enum BookmarkFilter: Hashable {
    case all
    case category(String)
    case tag(String)

    var title: String {
        switch self {
        case .all: "All"
        case .category(let value): value
        case .tag(let value): value
        }
    }
}

extension URL {
    var bookmarkDomain: String {
        (host(percentEncoded: false) ?? host ?? absoluteString)
            .replacing(/^www\./, with: "")
    }
}

extension String {
    var cleanedSingleLine: String {
        replacing(/\s+/, with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
