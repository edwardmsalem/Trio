import Foundation

/// Trio's treatment history and glucose readings in the shape AAPS's IOB, COB and glucose-status
/// code reads them, so the AAPS dosing mode can compute its inputs the way AAPS does
/// (see `AAPSIob`, `AAPSGlucoseStatusCalculator`, `AAPSMealCalculator`).
///
/// Times are epoch milliseconds, rates are absolute U/h.
struct AAPSHistory: Codable, Equatable {
    struct Bolus: Codable, Equatable {
        var time: Int64
        var amount: Double
    }

    /// A temp basal as AAPS stores it: one at a time, each ending when the next starts.
    struct TempBasal: Codable, Equatable {
        var time: Int64
        var duration: Int64
        var rate: Double

        var end: Int64 { time + duration }
    }

    struct Carbs: Codable, Equatable {
        var time: Int64
        var amount: Double
    }

    struct Glucose: Codable, Equatable {
        var time: Int64
        var value: Double
    }

    /// Scheduled basal, minutes from local midnight.
    struct BasalEntry: Codable, Equatable {
        var minutes: Int
        var rate: Double
    }

    var boluses: [Bolus] = []
    var temps: [TempBasal] = []
    var carbs: [Carbs] = []
    /// Carb entries already entered but dated after `now`, up to `upcomingCarbsWindow` ahead (Trio's
    /// fat and protein equivalents). Kept apart from `carbs`, which AAPS's COB reads: only the
    /// low-glucose guard looks at these. Optional so older encoded history still decodes.
    var upcomingCarbs: [Carbs]?
    /// Newest first, as AAPS keeps its readings.
    var glucose: [Glucose] = []
    var basalSchedule: [BasalEntry] = []
    /// Pod or infusion-set changes (pod activations, cannula fills, primes, rewinds), oldest first.
    /// Optional so older encoded history still decodes.
    var siteChanges: [Int64]?

    /// Scheduled basal at `time`, in local time (AAPS `profile.getBasal`).
    func basal(at time: Int64, calendar: Calendar) -> Double {
        guard !basalSchedule.isEmpty else { return 0 }
        let date = Date(timeIntervalSince1970: Double(time) / 1000)
        let comps = calendar.dateComponents([.hour, .minute, .second], from: date)
        let seconds = (comps.hour ?? 0) * 3600 + (comps.minute ?? 0) * 60 + (comps.second ?? 0)
        var rate = basalSchedule[0].rate
        for entry in basalSchedule where entry.minutes * 60 <= seconds {
            rate = entry.rate
        }
        return rate
    }
}

extension AAPSHistory {
    /// How far ahead an entered carb entry still counts as upcoming for the guard.
    static let upcomingCarbsWindow: TimeInterval = 2 * 3600

    private static func ms(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }
    private static func dbl(_ d: Decimal) -> Double { Double(truncating: d as NSNumber) }

    /// Builds the AAPS view of Trio's data.
    ///
    /// - Boluses (SMBs included) count with the amount Trio recorded.
    /// - Temp basals: each lasts its recorded duration, is cut by the next temp, by a scheduled-basal
    ///   marker and by a pump suspend, and never runs past `now`. A suspend becomes a zero temp until
    ///   the resume (or `now`), which is how AAPS records an Omnipod suspend. Percent temps are
    ///   converted with the scheduled basal at their start.
    /// - Carbs are every carb entry up to `now` (fat and protein equivalents included, as AAPS
    ///   counts extended carbs). Entries dated in the next 2 hours go to `upcomingCarbs` instead.
    /// - Site changes are the prime and rewind events in the pump history plus `siteChanges`, the
    ///   pod or infusion-set changes Trio stores outside the algorithm's pump history.
    static func from(
        pumpHistory: [PumpHistoryEvent],
        carbs: [CarbsEntry],
        glucose: [BloodGlucose],
        basalProfile: [BasalProfileEntry],
        now: Date,
        siteChanges: [Date] = [],
        calendar: Calendar = .current
    ) -> AAPSHistory {
        let nowMs = ms(now)
        var history = AAPSHistory()
        history.basalSchedule = basalProfile.map { BasalEntry(minutes: $0.minutes, rate: dbl($0.rate)) }
            .sorted { $0.minutes < $1.minutes }

        let events = pumpHistory.filter { $0.timestamp <= now }.sorted { $0.timestamp < $1.timestamp }

        history.boluses = events.compactMap { e -> Bolus? in
            guard e.type == .bolus, let amount = e.amount, amount > 0 else { return nil }
            return Bolus(time: ms(e.timestamp), amount: dbl(amount))
        }

        // Durations come on the temp event (Core Data path) or on its paired duration event.
        var durations: [Int64: Int] = [:]
        for e in events where e.type == .tempBasalDuration {
            if let minutes = e.durationMin { durations[ms(e.timestamp)] = minutes }
        }

        struct Span {
            var start: Int64
            var end: Int64
            var rate: Double?
            let isSuspend: Bool
        }
        var spans: [Span] = []
        for e in events where e.type == .tempBasal {
            let start = ms(e.timestamp)
            guard e.isScheduledBasal != true else {
                spans.append(Span(start: start, end: start, rate: nil, isSuspend: false))
                continue
            }
            let minutes = e.duration ?? durations[start] ?? 0
            guard let r = e.rate ?? e.amount else { continue }
            var rate = dbl(r)
            if e.temp == .percent { rate = rate / 100 * history.basal(at: start, calendar: calendar) }
            spans.append(Span(start: start, end: start + Int64(minutes) * 60000, rate: rate, isSuspend: false))
        }

        // Suspend periods become zero temps that end the temp running at the time.
        var suspendStart: Int64?
        for e in events where e.type == .pumpSuspend || e.type == .pumpResume {
            let t = ms(e.timestamp)
            if e.type == .pumpSuspend {
                if suspendStart == nil { suspendStart = t }
            } else if let s = suspendStart {
                spans.append(Span(start: s, end: t, rate: 0, isSuspend: true))
                suspendStart = nil
            }
        }
        if let s = suspendStart { spans.append(Span(start: s, end: nowMs, rate: 0, isSuspend: true)) }

        spans.sort { $0.start != $1.start ? $0.start < $1.start : ($0.isSuspend && !$1.isSuspend) }
        // Inside a suspend no temp runs: drop temps that start during one.
        var kept: [Span] = []
        for s in spans {
            if !s.isSuspend, let last = kept.last(where: \.isSuspend), s.start >= last.start, s.start < last.end { continue }
            kept.append(s)
        }
        for (i, s) in kept.enumerated() {
            guard let rate = s.rate else { continue }
            var end = min(s.end, nowMs)
            if i + 1 < kept.count { end = min(end, kept[i + 1].start) }
            if end > s.start { history.temps.append(TempBasal(time: s.start, duration: end - s.start, rate: rate)) }
        }

        history.carbs = carbs.compactMap { c -> Carbs? in
            let time = ms(c.createdAt)
            guard c.carbs > 0, time <= nowMs else { return nil }
            return Carbs(time: time, amount: dbl(c.carbs))
        }.sorted { $0.time < $1.time }
        let upcomingEnd = nowMs + Int64(upcomingCarbsWindow * 1000)
        history.upcomingCarbs = carbs.compactMap { c -> Carbs? in
            let time = ms(c.createdAt)
            guard c.carbs > 0, time > nowMs, time <= upcomingEnd else { return nil }
            return Carbs(time: time, amount: dbl(c.carbs))
        }.sorted { $0.time < $1.time }

        let primes = events.filter { $0.type == .prime || $0.type == .rewind }.map(\.timestamp)
        history.siteChanges = Set((primes + siteChanges).map(ms)).filter { $0 <= nowMs }.sorted()

        history.glucose = glucose.compactMap { g -> Glucose? in
            guard let value = g.glucose ?? g.sgv else { return nil }
            let time = ms(g.dateString)
            guard time <= nowMs else { return nil }
            return Glucose(time: time, value: Double(value))
        }.sorted { $0.time > $1.time }

        return history
    }
}
