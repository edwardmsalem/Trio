import Foundation

/// The ISF AAPS uses to turn deviations into absorbed carbs when Dynamic ISF is on.
///
/// AAPS (`ProfileSealed.getIsfMgdlForCarbs` -> `OpenAPSSMBPlugin.getAverageIsfMgdl`) averages the
/// dynamic ISF values in its `dynIsfCache` over the 24 hours before the time asked about, and
/// falls back to the profile ISF when there are none. The cache holds one value per key, the key
/// being the run time rounded down to 30 minutes plus the glucose in mg/dL, and AAPS refills it
/// from the last day of loop results when it starts. This keeps the same values for Trio's own
/// AAPS-mode runs.
struct AAPSCarbIsfCache: JSON, Equatable {
    struct Entry: Codable, Equatable {
        var key: Int64
        var value: Double
    }

    var entries: [Entry] = []

    static let window: Int64 = 24 * 60 * 60 * 1000

    /// AAPS `timestamp - timestamp % 30 min + glucose.toLong()`.
    static func key(time: Int64, glucose: Double) -> Int64 {
        time - time % (30 * 60 * 1000) + Int64(glucose)
    }

    /// Adds a run's dynamic ISF (latest value wins for a key) and drops keys older than a day.
    mutating func record(time: Int64, glucose: Double, variableSensitivity: Double) {
        guard variableSensitivity > 0 else { return }
        let key = Self.key(time: time, glucose: glucose)
        entries.removeAll { $0.key == key || $0.key < time - Self.window - 60 * 60 * 1000 }
        entries.append(Entry(key: key, value: variableSensitivity))
    }

    /// Mean of the values whose key lies in [time - 24 h, time], or nil when there are none.
    func average(upTo time: Int64) -> Double? {
        var sum = 0.0
        var count = 0
        for e in entries where e.key >= time - Self.window && e.key <= time {
            sum += e.value
            count += 1
        }
        return count == 0 ? nil : sum / Double(count)
    }
}
