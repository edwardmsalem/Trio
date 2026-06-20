import Foundation
import SwiftUI
import WidgetKit

/// Snapshot of current glucose shared from the main Trio app to the home-screen
/// and lock-screen WidgetKit widgets via the App Group. Mirrors what the watch
/// complication receives. Written by AppleWatchManager on every glucose push.
struct GlucoseWidgetData: Codable {
    var glucose: String // e.g. "120" or "6.7"
    var trend: String // arrow, e.g. "→"
    var delta: String // e.g. "+5"
    var iob: String?
    var cob: String?
    var colorString: String // "#ffffff" in-range; other = out of range
    var date: Date // timestamp of the reading

    private static let storeKey = "glucoseWidgetData.v1"

    /// App Group suite name, read from the bundle's Info.plist (AppGroupID).
    /// Works in both the main app and the widget extension.
    static var suiteName: String? {
        Bundle.main.object(forInfoDictionaryKey: "AppGroupID") as? String
    }

    static func sharedDefaults() -> UserDefaults? {
        guard let suiteName else { return nil }
        return UserDefaults(suiteName: suiteName)
    }

    func save() {
        guard let defaults = Self.sharedDefaults(),
              let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.storeKey)
    }

    static func load() -> GlucoseWidgetData? {
        guard let defaults = sharedDefaults(),
              let data = defaults.data(forKey: storeKey),
              let decoded = try? JSONDecoder().decode(GlucoseWidgetData.self, from: data)
        else { return nil }
        return decoded
    }

    // MARK: - Display helpers

    var minutesAgo: Int { max(0, Int(Date().timeIntervalSince(date) / 60)) }
    var isStale: Bool { minutesAgo > 10 }
    var isVeryStale: Bool { minutesAgo > 15 }

    /// Reading timestamp as "HH:mm".
    var timeString: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }

    /// Green = fresh, yellow = getting stale, red = very stale / no data.
    var stalenessColor: Color {
        if isVeryStale { return .red }
        if isStale { return .yellow }
        return .green
    }

    /// True when glucose is in range (white color sent by the app).
    var isInRange: Bool {
        let c = colorString.lowercased()
        return c == "#ffffff" || c == "ffffff"
    }

    static var placeholder: GlucoseWidgetData {
        GlucoseWidgetData(
            glucose: "120",
            trend: "→",
            delta: "+2",
            iob: "1.2",
            cob: "15",
            colorString: "#ffffff",
            date: Date()
        )
    }
}
