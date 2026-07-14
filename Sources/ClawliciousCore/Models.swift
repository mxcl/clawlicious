import Foundation

public struct Bookmark: Identifiable, Codable, Hashable, Sendable {
    public enum Status: String, Codable, Sendable {
        case pending
        case summarized
        case failed
    }

    public var id: UUID
    public var url: URL
    public var domain: String
    public var title: String
    public var summary: String
    public var tags: [String]
    public var category: String
    public var createdAt: Date
    public var updatedAt: Date
    public var status: Status
    public var error: String?
    public var contentWarning: String? = nil

    public init(id: UUID, url: URL, domain: String, title: String, summary: String, tags: [String], category: String, createdAt: Date, updatedAt: Date, status: Status, error: String?, contentWarning: String? = nil) {
        self.id = id
        self.url = url
        self.domain = domain
        self.title = title
        self.summary = summary
        self.tags = tags
        self.category = category
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.status = status
        self.error = error
        self.contentWarning = contentWarning
    }
}

public struct BookmarkMetadata: Codable, Equatable, Sendable {
    public var title: String
    public var summary: String
    public var tags: [String]
    public var category: String
    public var contentWarning: String? = nil

    public init(title: String, summary: String, tags: [String], category: String, contentWarning: String? = nil) {
        self.title = title
        self.summary = summary
        self.tags = tags
        self.category = category
        self.contentWarning = contentWarning
    }
}

public enum BookmarkFilter: Hashable {
    case all
    case category(String)
    case tag(String)

    public var title: String {
        switch self {
        case .all: "All"
        case .category(let value): value
        case .tag(let value): value
        }
    }
}

public extension URL {
    var bookmarkDomain: String {
        (host(percentEncoded: false) ?? host ?? absoluteString)
            .replacing(/^www\./, with: "")
    }
}

public extension String {
    var cleanedSingleLine: String {
        replacing(/\s+/, with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
