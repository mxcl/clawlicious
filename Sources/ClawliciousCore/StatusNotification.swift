import Foundation

public enum ClawliciousStatusNotification {
    public static let name = Notification.Name("dev.mxcl.clawlicious.status")
    public static let messageKey = "message"

    public static func post(_ message: String) {
        DistributedNotificationCenter.default().postNotificationName(
            name,
            object: nil,
            userInfo: [messageKey: message],
            options: [.deliverImmediately]
        )
    }
}

public enum ClawliciousLibraryNotification {
    public static let name = Notification.Name("dev.mxcl.clawlicious.library-changed")
    public static let bookmarkIDKey = "bookmarkID"
    public static let statusKey = "status"

    public static func post(bookmarkID: Bookmark.ID? = nil, status: Bookmark.Status? = nil) {
        var userInfo: [String: String] = [:]
        userInfo[bookmarkIDKey] = bookmarkID?.uuidString
        userInfo[statusKey] = status?.rawValue
        DistributedNotificationCenter.default().postNotificationName(
            name,
            object: nil,
            userInfo: userInfo,
            options: [.deliverImmediately]
        )
    }
}
