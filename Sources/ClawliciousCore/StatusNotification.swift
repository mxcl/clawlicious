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
