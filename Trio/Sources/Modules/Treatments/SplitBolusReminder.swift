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
    private static let idPrefix = "trio.splitBolusReminder"

    /// Escalation schedule (minutes AFTER the chosen delay) — the reminder keeps
    /// firing until the dose is delivered (which calls `clear()`), so a single missed
    /// alert never means a missed committed dose.
    private static let escalationOffsets: [Int] = [0, 4, 9, 16, 26, 41, 61]

    private static func allIds() -> [String] { escalationOffsets.indices.map { "\(idPrefix).\($0)" } }

    struct Pending: Codable {
        let remaining: Decimal
        let dueDate: Date
    }

    /// Schedule escalating reminders for the remaining units after `minutes`.
    static func schedule(remaining: Decimal, after minutes: Int) {
        guard remaining > 0, minutes > 0 else { return }

        let due = Date().addingTimeInterval(TimeInterval(minutes * 60))
        if let data = try? JSONEncoder().encode(Pending(remaining: remaining, dueDate: due)) {
            UserDefaults.standard.set(data, forKey: storeKey)
        }

        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: allIds())

        let amountString = NSDecimalNumber(decimal: remaining).doubleValue
            .formatted(.number.precision(.fractionLength(0 ... 2)))

        for (index, offset) in escalationOffsets.enumerated() {
            let content = UNMutableNotificationContent()
            if index == 0 {
                content.title = String(localized: "Finish your meal bolus")
                content.body = String(localized: "\(amountString) U remaining — tap Deliver to review and dose.")
            } else {
                content.title = String(localized: "⚠️ Bolus still not finished")
                content.body = String(localized: "You still owe \(amountString) U from your meal. Tap Deliver now.")
            }
            content.sound = .default
            content.interruptionLevel = .timeSensitive
            content.categoryIdentifier = "TRIO_SPLIT_BOLUS"
            content.userInfo = ["action": "splitBolus"]

            let seconds = TimeInterval((minutes + offset) * 60)
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: seconds, repeats: false)
            center.add(UNNotificationRequest(identifier: "\(idPrefix).\(index)", content: content, trigger: trigger))
        }
    }

    static func pending() -> Pending? {
        guard let data = UserDefaults.standard.data(forKey: storeKey),
              let pending = try? JSONDecoder().decode(Pending.self, from: data) else { return nil }
        return pending
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: storeKey)
        let center = UNUserNotificationCenter.current()
        let ids = allIds()
        center.removePendingNotificationRequests(withIdentifiers: ids)
        center.removeDeliveredNotifications(withIdentifiers: ids)
    }
}
