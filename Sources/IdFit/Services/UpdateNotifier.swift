import Foundation
import UserNotifications

/// Announces a new release through Notification Center.
///
/// A notification rather than a window: the check runs at launch, when
/// somebody has just come to work on a document, and a modal alert in that
/// moment interrupts the thing they opened the app to do. A banner waits in
/// Notification Center instead, and leaving it alone is a complete answer —
/// the next launch a day or more later asks again.
enum UpdateNotifier {
    static let category = "update"
    static let downloadAction = "download"
    static let laterAction = "later"
    /// Carries the release page through to whichever button gets pressed.
    static let pageKey = "page"

    /// Registered once at launch: the buttons belong to the category, not to
    /// the individual notification.
    static func registerCategory() {
        let download = UNNotificationAction(
            identifier: downloadAction, title: "Download", options: [.foreground]
        )
        let later = UNNotificationAction(identifier: laterAction, title: "Later", options: [])
        UNUserNotificationCenter.current().setNotificationCategories([
            UNNotificationCategory(
                identifier: category,
                actions: [download, later],
                intentIdentifiers: [],
                options: []
            )
        ])
    }

    /// - Returns: whether the notification was handed over. `false` means the
    ///   system will not show it — permission was refused, or asking failed —
    ///   and the caller should fall back to asking in the window rather than
    ///   let the news disappear.
    static func post(release: UpdateChecker.Release, currentVersion: String) async -> Bool {
        let center = UNUserNotificationCenter.current()
        guard await isAllowed(center) else { return false }

        let content = UNMutableNotificationContent()
        content.title = "ID Fit \(release.version) is available"
        content.body = "You have \(currentVersion). Download it now, or leave this for next time."
        content.categoryIdentifier = category
        content.userInfo = [pageKey: release.page.absoluteString]

        // One notification per version: relaunching within the day must not
        // stack up copies of the same news.
        let request = UNNotificationRequest(
            identifier: "update-\(release.version)", content: content, trigger: nil
        )
        do {
            try await center.add(request)
            return true
        } catch {
            return false
        }
    }

    private static func isAllowed(_ center: UNUserNotificationCenter) async -> Bool {
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional:
            true
        case .notDetermined:
            // Asked the first time an update actually exists, so the system
            // prompt arrives with a reason rather than on a blank first run.
            (try? await center.requestAuthorization(options: [.alert])) ?? false
        default:
            false
        }
    }

    /// The page a pressed notification points at, if it is one of ours and the
    /// button pressed was not "Later".
    static func page(for response: UNNotificationResponse) -> URL? {
        guard response.actionIdentifier == downloadAction
            || response.actionIdentifier == UNNotificationDefaultActionIdentifier
        else { return nil }
        guard let string = response.notification.request.content.userInfo[pageKey] as? String
        else { return nil }
        return URL(string: string)
    }
}
