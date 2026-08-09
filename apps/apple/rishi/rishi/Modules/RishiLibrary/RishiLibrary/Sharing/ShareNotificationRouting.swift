import Foundation

public enum ShareNotificationRouting {
    public static let notificationTapped = Notification.Name("Rishi.shareNotificationTapped")

    public static func isShareCreated(userInfo: [AnyHashable: Any]) -> Bool {
        guard let rishi = userInfo["rishi"] as? [String: Any],
              let kind = rishi["kind"] as? String else {
            return false
        }
        return kind == "share.created"
    }
}
