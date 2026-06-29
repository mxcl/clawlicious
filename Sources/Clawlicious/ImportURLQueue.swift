import Foundation

@MainActor
final class ImportURLQueue {
    static let shared = ImportURLQueue()

    private var urlStrings: [String] = []

    private init() {}

    func enqueue(_ urlString: String) {
        urlStrings.append(urlString)
        NotificationCenter.default.post(name: .clawliciousQueuedImportBookmark, object: nil)
    }

    func drain() -> [String] {
        defer { urlStrings.removeAll() }
        return urlStrings
    }
}
