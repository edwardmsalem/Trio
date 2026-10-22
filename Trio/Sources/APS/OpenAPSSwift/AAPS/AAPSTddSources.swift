import Foundation

/// Builds the TDD figures AAPS Dynamic ISF needs from what Trio stores.
///
/// AAPS reads five insulin totals from its TddCalculator: yesterday (midnight to midnight), the
/// average of the last 7 complete days, the rolling last 24 hours, the last 4 hours and the 4 hours
/// before that. Trio has no such calculator, so:
///
/// - Yesterday and the 7-day average come from Trio's stored TDD records (`TDDStored`). Trio
///   stores a rolling 24 hour total every loop, so the record nearest each local midnight is that
///   calendar day's total. AAPS refuses a 7-day average with a missing day, and so does this: any
///   midnight without a record within 15 minutes makes the parts incomplete, and the AAPS mode then
///   runs without Dynamic ISF, which is what AAPS does.
/// - The 24 h, 4 h and 8-to-4 h windows are summed from the pump history the loop already loads,
///   the way AAPS's `calculateInterval` sums them: every bolus in the window, plus basal in 5 minute
///   steps at the rate running at each step (temp basal, zero while suspended, else the profile).
/// - Carbs for the autosens carbs ratio come from Trio's carb entries, excluding the fat and protein
///   equivalents Trio adds (AAPS has no such entries).
enum AAPSTddSources {
    static let midnightTolerance: TimeInterval = 15 * 60

    /// Yesterday's total and the 7-day average from stored rolling-24 h TDD records.
    static func dailyTotals(
        records: [(date: Date, total: Double)],
        now: Date,
        calendar: Calendar = .current
    ) -> (tdd1D: Double?, tdd7D: Double?) {
        let today = calendar.startOfDay(for: now)
        func dayTotal(endingAt midnight: Date) -> Double? {
            let near = records.filter { abs($0.date.timeIntervalSince(midnight)) <= midnightTolerance && $0.total > 0 }
            return near.min { abs($0.date.timeIntervalSince(midnight)) < abs($1.date.timeIntervalSince(midnight)) }?.total
        }
        // day k ends at the midnight k-1 days before today's
        var totals: [Double] = []
        for k in 0 ..< 7 {
            guard let midnight = calendar.date(byAdding: .day, value: -k, to: today), let total = dayTotal(endingAt: midnight)
            else { break }
            totals.append(total)
        }
        let tdd1D = totals.first
        let tdd7D = totals.count == 7 ? totals.reduce(0, +) / 7.0 : nil
        return (tdd1D, tdd7D)
    }

    /// Carbs entered in the last 24 hours, the 7-day daily average over the same complete days as
    /// `tdd7D`, and whether every one of those days had carbs.
    static func carbTotals(
        entries: [(date: Date, carbs: Double)],
        now: Date,
        calendar: Calendar = .current
    ) -> (last24h: Double, sevenDayAverage: Double, allDaysHaveCarbs: Bool) {
        let last24h = entries.filter { $0.date > now.addingTimeInterval(-86400) && $0.date <= now }.map(\.carbs).reduce(0, +)
        let today = calendar.startOfDay(for: now)
        var dayTotals: [Double] = []
        for k in 1 ... 7 {
            guard let start = calendar.date(byAdding: .day, value: -k, to: today),
                  let end = calendar.date(byAdding: .day, value: -k + 1, to: today) else { continue }
            dayTotals.append(entries.filter { $0.date >= start && $0.date < end }.map(\.carbs).reduce(0, +))
        }
        let average = dayTotals.isEmpty ? 0 : dayTotals.reduce(0, +) / Double(dayTotals.count)
        return (last24h, average, !dayTotals.isEmpty && !dayTotals.contains(0))
    }

    /// Insulin delivered in `[start, end)` the way AAPS `TddCalculator.calculateInterval` counts it.
    /// Returns nil when the pump history does not reach back to `start`, as AAPS returns nil for an
    /// interval it has no data for.
    static func insulin(
        from start: Date,
        to end: Date,
        pumpHistory: [PumpHistoryEvent],
        basalProfile: [BasalProfileEntry],
        now: Date,
        calendar: Calendar = .current
    ) -> Double? {
        guard !basalProfile.isEmpty, let earliest = pumpHistory.map(\.timestamp).min(), earliest <= start.addingTimeInterval(3600)
        else { return nil }

        let boluses = pumpHistory
            .filter { $0.type == .bolus && $0.timestamp >= start && $0.timestamp < end }
            .compactMap { $0.amount.map { Double(truncating: $0 as NSNumber) } }
            .reduce(0, +)

        // temp basal spans, each clipped to the next temp and to now
        let temps = pumpHistory
            .filter { $0.type == .tempBasal && $0.isScheduledBasal != true }
            .compactMap { e -> (start: Date, end: Date, rate: Double)? in
                guard let minutes = e.duration, let rate = e.amount ?? e.rate else { return nil }
                return (
                    e.timestamp,
                    e.timestamp.addingTimeInterval(TimeInterval(minutes * 60)),
                    Double(truncating: rate as NSNumber)
                )
            }
            .sorted { $0.start < $1.start }
        var spans: [(start: Date, end: Date, rate: Double)] = []
        for (i, t) in temps.enumerated() {
            var e = min(t.end, now)
            if i + 1 < temps.count { e = min(e, temps[i + 1].start) }
            if e > t.start { spans.append((t.start, e, t.rate)) }
        }
        let suspensions = BaseTDDStorage.suspensionSpans(
            suspends: pumpHistory.filter { $0.type == .pumpSuspend },
            resumes: pumpHistory.filter { $0.type == .pumpResume },
            now: now
        )

        let step: TimeInterval = 5 * 60
        let alignedStart = Date(timeIntervalSince1970: (start.timeIntervalSince1970 / step).rounded(.down) * step)
        let alignedEnd = Date(timeIntervalSince1970: (end.timeIntervalSince1970 / step).rounded(.down) * step)
        var basal = 0.0
        var t = alignedStart
        while t < alignedEnd {
            let rate: Double
            if suspensions.contains(where: { t >= $0.start && t < $0.end }) {
                rate = 0
            } else if let span = spans.last(where: { t >= $0.start && t < $0.end }) {
                rate = span.rate
            } else {
                let comps = calendar.dateComponents([.hour, .minute], from: t)
                let minutes = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
                rate = findBasalRateForOffset(for: minutes, in: basalProfile).map { Double(truncating: $0 as NSNumber) } ?? 0
            }
            basal += rate / 60.0 * 5.0
            t = t.addingTimeInterval(step)
        }
        return boluses + basal
    }
}
