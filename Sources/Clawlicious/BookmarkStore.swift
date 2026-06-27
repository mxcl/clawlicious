import Foundation

struct BookmarkStore: Sendable {
    var load: @Sendable () throws -> [Bookmark]
    var save: @Sendable ([Bookmark]) throws -> Void

    static let live = BookmarkStore(
        load: {
            let url = try storageURL()
            guard FileManager.default.fileExists(atPath: url.path) else { return [] }
            let data = try Data(contentsOf: url)
            return try JSONDecoder.clawlicious.decode([Bookmark].self, from: data)
        },
        save: { bookmarks in
            let url = try storageURL()
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder.clawlicious.encode(bookmarks)
            try data.write(to: url, options: [.atomic])
        }
    )
}

func clawliciousApplicationSupportURL() throws -> URL {
    let base = try FileManager.default.url(
        for: .applicationSupportDirectory,
        in: .userDomainMask,
        appropriateFor: nil,
        create: true
    )
    return base.appending(path: "Clawlicious", directoryHint: .isDirectory)
}

private func storageURL() throws -> URL {
    try clawliciousApplicationSupportURL().appending(path: "bookmarks.json")
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
