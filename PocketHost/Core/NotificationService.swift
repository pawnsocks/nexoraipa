import Foundation
import UserNotifications

final class NotificationService: @unchecked Sendable {
    static let shared = NotificationService()
    private init() {}

    func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    func send(title: String, body: String, projectID: String? = nil) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if let projectID { content.userInfo = ["projectID": projectID] }
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
