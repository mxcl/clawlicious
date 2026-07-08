import Foundation

@MainActor
final class ImportURLQueue {
    struct Request {
        var urlString: String
        var notifyOnCompletion: Bool
    }

    static let shared = ImportURLQueue()

    private var requests: [Request] = []

    private init() {}

    func enqueue(_ urlString: String, notifyOnCompletion: Bool = false) {
        requests.append(Request(urlString: urlString, notifyOnCompletion: notifyOnCompletion))
        NotificationCenter.default.post(name: .clawliciousQueuedImportBookmark, object: nil)
    }

    func drain() -> [Request] {
        defer { requests.removeAll() }
        return requests
    }
}
