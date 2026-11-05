import AppKit
import MCleanCore
import UserNotifications

/// Notifications système ; l'autorisation n'est demandée qu'au premier envoi.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()
    private static let inactiveCategory = "inactive"
    private static let quitAction = "quit"
    private weak var model: AppModel?

    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : .current() // absent hors d'un paquet .app
    }

    func configure(model: AppModel) {
        self.model = model
        center?.delegate = self
        let quit = UNNotificationAction(identifier: Self.quitAction, title: L("action.quit"), options: [])
        center?.setNotificationCategories([UNNotificationCategory(identifier: Self.inactiveCategory, actions: [quit], intentIdentifiers: [])])
    }

    private func send(id: String, title: String, body: String, category: String = "", info: [String: String] = [:]) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.categoryIdentifier = category
        content.userInfo = info
        center.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
        }
    }

    func cleaned(_ result: CleanResult) {
        send(id: "clean", title: L("notify.cleanTitle"), body: L("notify.cleanBody", MemoryFormat.size(result.freed), MemoryFormat.size(result.after.free)))
    }

    func inactive(app: AppUsage) {
        send(id: "inactive.\(app.bundleID)", title: L("notify.inactiveTitle", app.name), body: L("notify.inactiveBody", MemoryFormat.size(app.bytes)),
             category: Self.inactiveCategory, info: ["bundleID": app.bundleID])
    }

    /// Alerte du garde-fou ; avec `bundleID`, le bouton « Quitter » est proposé.
    func guardAlert(id: String, title: String, body: String, bundleID: String?) {
        send(id: "guard.\(id)", title: title, body: body, category: bundleID == nil ? "" : Self.inactiveCategory,
             info: bundleID.map { ["bundleID": $0] } ?? [:])
    }

    func guardQuit(app: AppUsage) {
        send(id: "guard.quit.\(app.bundleID)", title: L("notify.guardQuitTitle", app.name), body: L("notify.guardQuitBody", MemoryFormat.size(app.bytes)))
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let action = response.actionIdentifier
        let id = response.notification.request.content.userInfo["bundleID"] as? String
        if action == Self.quitAction, let id {
            Task { @MainActor in
                NSRunningApplication.runningApplications(withBundleIdentifier: id).first?.terminate()
            }
        }
        completionHandler()
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner])
    }
}
