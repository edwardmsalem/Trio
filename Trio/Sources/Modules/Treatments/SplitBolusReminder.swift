import Foundation
import UserNotifications

/// Backs the "split bolus" helper: when the user delivers part of a meal bolus now
/// and wants the rest later, this stores the remaining amount and fires a local
/// reminder at the chosen time.
///
/// SAFETY: this NEVER delivers insulin. It only schedules a reminder and pre-fills
/// the bolus screen when tapped, so the user always confirms the remaining dose
/// through Trio's normal safety-checked bolus flow (auth, max-bolus, live IOB).
enum SplitBolusReminder {
    private static let storeKey = "splitBolusReminder.v1"
    private static let notificationId = "trio.splitBolusReminder"

    struct Pending: Codable {
        let remaining: Decimal
        let dueDate: Date
    }

    /// Schedule a reminder for the remaining units after `minutes`.
    static func schedule(remaining: Decimal, after minutes: Int) {
        guard remaining > 0, minutes > 0 else { return }

        let due = Date().addingTimeInterval(TimeInterval(minutes * 60))
        if let data = try? JSONEncoder().encode(Pending(remaining: remaining, dueDate: due)) {
            UserDefaults.standard.set(data, forKey: storeKey)
        }

        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [notificationId])

        let amountString = NSDecimalNumber(decimal: remaining).doubleValue
            .formatted(.number.precision(.fractionLength(0 ... 2)))

        let content = UNMutableNotificationContent()
        content.title = String(localized: "Finish your meal bolus")
        content.body = String(localized: "\(amountString) U remaining — tap to review and deliver.")
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        content.userInfo = ["deepLink": "Trio://treatments"]

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: TimeInterval(minutes * 60), repeats: false)
        center.add(UNNotificationRequest(identifier: notificationId, content: content, trigger: trigger))
    }

    static func pending() -> Pending? {
        guard let data = UserDefaults.standard.data(forKey: storeKey),
              let pending = try? JSONDecoder().decode(Pending.self, from: data) else { return nil }
        return pending
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: storeKey)
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [notificationId])
        center.removeDeliveredNotifications(withIdentifiers: [notificationId])
    }
}
