import Foundation
import UserNotifications

#if canImport(UIKit)
    import UIKit
#endif

/// Explains the sharing notification use case before iOS presents its
/// system permission prompt. The primer is shown once, only while permission
/// is still undecided; denied users retain the manual inbox fallback.
public enum NotificationPermissionCoordinator {
    private static let primerShownKey = "rishi.notifications.permission-primer-shown"

    public static func shouldShowPrimer() async -> Bool {
        guard !UserDefaults.standard.bool(forKey: primerShownKey) else { return false }
        let status = await authorizationStatus()
        return status == .notDetermined
    }

    public static func markPrimerShown() {
        UserDefaults.standard.set(true, forKey: primerShownKey)
    }

    public static func requestAuthorization() async {
        markPrimerShown()
        do {
            _ = try await UNUserNotificationCenter.current().requestAuthorization(
                options: [.alert, .badge, .sound]
            )
        } catch {
            Log.error("notifications.authorization.failed", error: error)
        }

        #if canImport(UIKit)
            await MainActor.run {
                UIApplication.shared.registerForRemoteNotifications()
            }
        #endif
    }

    private static func authorizationStatus() async -> UNAuthorizationStatus {
        await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                continuation.resume(returning: settings.authorizationStatus)
            }
        }
    }
}
