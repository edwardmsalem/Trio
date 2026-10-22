import Foundation
import SwiftUI
import WidgetKit

/// Snapshot of current glucose shared from the main Trio app to the home-screen
/// and lock-screen WidgetKit widgets via the App Group. Written by
/// LiveActivityManager (the same Core Data trigger that keeps the Live Activity
/// current, foreground and background) on every new reading.
/// One sampled glucose point for the large widget's trend chart. `glucose` is in
/// the user's display unit (mg/dL or mmol/L), matching the big number shown.
struct WidgetGlucosePoint: Codable, Identifiable {
    var id: Date { date }
    let date: Date
    let glucose: Double
}

struct GlucoseWidgetData: Codable {
    var glucose: String // e.g. "120" or "6.7"
    var trend: String // arrow, e.g. "→"
    var delta: String // e.g. "+5"
    var iob: String?
    var cob: String?
    var colorString: String // "#ffffff" in-range; other = out of range
    var date: Date // timestamp of the CGM reading itself (not when it was sent)
    var history: [WidgetGlucosePoint]? = nil // recent readings for the large widget chart
    var low: Double? = nil // low target line (display unit) for the chart band
    var high: Double? = nil // high target line (display unit) for the chart band
    var lastLoopDate: Date? = nil // when the loop last ran

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

    /// How old a reading looks at a given moment. Widgets render entries ahead of
    /// time, so callers pass the timeline entry's date rather than `Date()`.
    enum Freshness {
        case fresh // up to 10 min
        case aging // 10 to 15 min: yellow dot only
        case stale // over 15 min: dimmed value plus warning symbol
        case veryStale // over 30 min: dimmed further, struck through, red symbol
    }

    static let agingAfter: TimeInterval = 10 * 60
    static let staleAfter: TimeInterval = 15 * 60
    static let veryStaleAfter: TimeInterval = 30 * 60

    func age(at reference: Date) -> TimeInterval { max(0, reference.timeIntervalSince(date)) }

    func freshness(at reference: Date) -> Freshness {
        let age = age(at: reference)
        if age > Self.veryStaleAfter { return .veryStale }
        if age > Self.staleAfter { return .stale }
        if age > Self.agingAfter { return .aging }
        return .fresh
    }

    /// Reading timestamp as "HH:mm".
    var timeString: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }

    /// Green = fresh, yellow = getting stale, red = stale / no data.
    func stalenessColor(at reference: Date) -> Color {
        switch freshness(at: reference) {
        case .fresh: return .green
        case .aging: return .yellow
        case .stale,
             .veryStale: return .red
        }
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
