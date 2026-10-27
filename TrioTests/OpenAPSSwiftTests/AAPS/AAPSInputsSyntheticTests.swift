import Foundation
import Testing
@testable import Trio

/// Made-up numbers only. Covers the AAPS-mode input ports: IOB, glucose status, COB and the carb
/// ISF cache, and the conversion of Trio's history into AAPS's shape.
@Suite("AAPS dosing inputs synthetic") struct AAPSInputsSyntheticTests {
    static let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    /// 2026-01-01 12:00:00 UTC
    static let now: Int64 = 1_767_268_800_000
    static let minute: Int64 = 60000
    static let curve = AAPSIob.Curve(diaHours: 5, peakMinutes: 75)

    // MARK: - IOB

    /// Expected values from the Python AAPS IOB port that reproduces AAPS's logged IOB on Eddie's
    /// loop runs (990 of 1,020 exactly, the rest are Nightscout history gaps).
    @Test("IOB array matches the AAPS calculation") func iobMatchesAAPS() {
        var h = AAPSHistory()
        h.basalSchedule = [.init(minutes: 0, rate: 1.0), .init(minutes: 660, rate: 0.8)]
        h.boluses = [
            .init(time: Self.now - 5 * 3_600_000 - Self.minute, amount: 1.0), // older than DIA, ignored
            .init(time: Self.now - 60 * Self.minute - 30000, amount: 2.0),
            .init(time: Self.now - 7 * Self.minute - 20000, amount: 0.3)
        ]
        h.temps = [
            .init(time: Self.now - 5 * 3_600_000 - 10 * Self.minute, duration: 30 * Self.minute, rate: 3.0),
            // started over DIA ago
            .init(time: Self.now - 95 * Self.minute, duration: 30 * Self.minute, rate: 2.5), // crosses the 11:00 basal change
            .init(time: Self.now - 50 * Self.minute, duration: 20 * Self.minute, rate: 0),
            .init(time: Self.now - 12 * Self.minute, duration: 30 * Self.minute, rate: 1.6) // still running
        ]
        let iob = AAPSIob.iobArray(history: h, now: Self.now, autosensRatio: 1.2, curve: Self.curve, calendar: Self.utc)
        #expect(iob.count == 48)
        #expect(iob[0].iob == 2.085)
        #expect(iob[0].activity == 0.0149)
        #expect(iob[0].iobWithZeroTemp == .init(iob: 2.085, activity: 0.0149)) // zero temp starts a minute after now
        #expect(iob[0].lastBolusTime == Self.now - 7 * Self.minute - 20000)
        #expect(iob[1].iob == 2.009)
        #expect(iob[1].iobWithZeroTemp == .init(iob: 1.945, activity: 0.0153))
        #expect(iob[6].iob == 1.616)
        #expect(iob[6].iobWithZeroTemp == .init(iob: 1.164, activity: 0.0147))
        #expect(iob[47].iob == 0.011)
        #expect(iob[47].iobWithZeroTemp == .init(iob: -1.766, activity: -0.0149))
    }

    @Test("temp basal IOB counts against the scheduled basal times the autosens ratio") func tempAgainstScaledBasal() {
        var h = AAPSHistory()
        h.basalSchedule = [.init(minutes: 0, rate: 1.0)]
        h.temps = [.init(time: Self.now - 60 * Self.minute, duration: 60 * Self.minute, rate: 1.0)]
        let plain = AAPSIob.iobArray(history: h, now: Self.now, autosensRatio: 1.0, curve: Self.curve, calendar: Self.utc)
        let resistant = AAPSIob.iobArray(history: h, now: Self.now, autosensRatio: 1.2, curve: Self.curve, calendar: Self.utc)
        #expect(plain[0].iob == 0)
        // the temp equals the scheduled basal, but against 1.2 x basal it is 0.2 U/h short
        #expect(resistant[0].iob < -0.15)
        #expect(resistant[0].iob > -0.2)
    }

    @Test("minutes since a bolus are exact, not rounded") func exactMinutes() {
        let a = AAPSIob.treatment(amount: 1, time: 0, at: 60 * Self.minute + 29000, curve: Self.curve)
        let b = AAPSIob.treatment(amount: 1, time: 0, at: 60 * Self.minute, curve: Self.curve)
        #expect(a.iob < b.iob)
        #expect(AAPSIob.treatment(amount: 1, time: 0, at: 300 * Self.minute, curve: Self.curve).iob == 0)
    }

    // MARK: - History conversion

    static func date(_ ms: Int64) -> Date { Date(timeIntervalSince1970: Double(ms) / 1000) }

    @Test("Trio pump history becomes one AAPS temp at a time") func historyConversion() {
        let t0 = Self.now - 60 * Self.minute
        func temp(_ at: Int64, _ rate: Decimal, _ minutes: Int) -> [PumpHistoryEvent] {
            [
                PumpHistoryEvent(id: "t\(at)", type: .tempBasal, timestamp: Self.date(at), rate: rate, temp: .absolute),
                PumpHistoryEvent(id: "d\(at)", type: .tempBasalDuration, timestamp: Self.date(at), durationMin: minutes)
            ]
        }
        let events = temp(t0, 2.0, 30) + temp(t0 + 10 * Self.minute, 0.5, 30) + [
            PumpHistoryEvent(id: "s", type: .pumpSuspend, timestamp: Self.date(t0 + 20 * Self.minute)),
            PumpHistoryEvent(id: "r", type: .pumpResume, timestamp: Self.date(t0 + 25 * Self.minute)),
            PumpHistoryEvent(id: "b", type: .bolus, timestamp: Self.date(t0 + 26 * Self.minute), amount: 0.4, isSMB: true)
        ] + temp(t0 + 50 * Self.minute, 1.2, 30) + temp(t0 + 70 * Self.minute, 3.0, 30) // the last is in the future
        let h = AAPSHistory.from(
            pumpHistory: events, carbs: [], glucose: [],
            basalProfile: [BasalProfileEntry(start: "00:00:00", minutes: 0, rate: 1)],
            now: Self.date(Self.now), calendar: Self.utc
        )
        #expect(h.temps == [
            .init(time: t0, duration: 10 * Self.minute, rate: 2.0),
            .init(time: t0 + 10 * Self.minute, duration: 10 * Self.minute, rate: 0.5),
            .init(time: t0 + 20 * Self.minute, duration: 5 * Self.minute, rate: 0), // the suspend
            .init(time: t0 + 50 * Self.minute, duration: 10 * Self.minute, rate: 1.2) // running, ends at now
        ])
        #expect(h.boluses == [.init(time: t0 + 26 * Self.minute, amount: 0.4)])
    }

    @Test("future-dated carbs within 4 hours are upcoming, not COB") func upcomingCarbsSplit() throws {
        func entry(_ minutesFromNow: Int64, _ grams: Decimal) -> CarbsEntry {
            let d = Self.date(Self.now + minutesFromNow * Self.minute)
            return CarbsEntry(
                id: "c\(minutesFromNow)", createdAt: d, actualDate: d, carbs: grams, fat: nil, protein: nil, note: nil,
                enteredBy: CarbsEntry.local, isFPU: minutesFromNow > 0, fpuID: nil
            )
        }
        let h = AAPSHistory.from(
            pumpHistory: [], carbs: [entry(-30, 40), entry(0, 5), entry(60, 12), entry(239, 10), entry(241, 30), entry(90, 0)],
            glucose: [], basalProfile: [BasalProfileEntry(start: "00:00:00", minutes: 0, rate: 1)],
            now: Self.date(Self.now), calendar: Self.utc
        )
        #expect(h.carbs == [.init(time: Self.now - 30 * Self.minute, amount: 40), .init(time: Self.now, amount: 5)])
        #expect(h.upcomingCarbs == [
            .init(time: Self.now + 60 * Self.minute, amount: 12),
            .init(time: Self.now + 239 * Self.minute, amount: 10)
        ])
        // history encoded before the field existed still decodes
        let old = try JSONDecoder()
            .decode(AAPSHistory.self, from: Data(#"{"boluses":[],"temps":[],"carbs":[],"glucose":[],"basalSchedule":[]}"#.utf8))
        #expect(old.upcomingCarbs == nil)
    }

    // MARK: - Glucose status

    static func readings(_ values: [(minutesAgo: Int64, value: Double)]) -> [AAPSHistory.Glucose] {
        values.map { AAPSHistory.Glucose(time: Self.now - 20000 - $0.minutesAgo * Self.minute, value: $0.value) }
    }

    @Test("deltas on the 5-minute grid") func deltas() throws {
        let r = Self
            .readings([(0, 120), (5, 117), (10, 114), (15, 110), (20, 108), (25, 105), (30, 101), (35, 99), (40, 95), (45, 90)])
        let gs = try #require(AAPSGlucoseStatusCalculator.glucoseStatus(
            buckets: AAPSGlucoseStatusCalculator.bucketedData(r), now: Self.now
        ))
        #expect(gs.glucose == 120)
        #expect(gs.delta == 3)
        #expect(gs.shortAvgDelta == 3.11)
        #expect(gs.longAvgDelta == 3.06)
        #expect(gs.date == Self.now - 20000)
    }

    @Test("a missed reading is filled in, so delta is not zero") func gapIsInterpolated() throws {
        let r = Self.readings([(0, 120), (10, 114), (15, 110), (20, 108)])
        let gs = try #require(AAPSGlucoseStatusCalculator.glucoseStatus(
            buckets: AAPSGlucoseStatusCalculator.bucketedData(r), now: Self.now
        ))
        #expect(gs.delta == 3) // from the interpolated 117 five minutes back
        // Trio's own status has no reading 2.5 to 7.5 minutes back and gives 0
        let trio = try #require(try DeterminationGenerator.getGlucoseStatus(glucoseReadings: r.map {
            BloodGlucose(sgv: Int($0.value), date: Decimal($0.time), dateString: Self.date($0.time), glucose: Int($0.value))
        }))
        #expect(trio.delta == 0)
    }

    @Test("with no usable reading 5 minutes back, delta is the short average") func deltaFallsBackToShortAverage() throws {
        let r = Self.readings([(0, 120), (5, 38), (10, 114), (15, 111), (20, 108)])
        let gs = try #require(AAPSGlucoseStatusCalculator.glucoseStatus(
            buckets: AAPSGlucoseStatusCalculator.bucketedData(r), now: Self.now
        ))
        #expect(gs.delta == gs.shortAvgDelta)
        #expect(gs.shortAvgDelta == 3) // (6 / 10 + 9 / 15) / 2 x 5
    }

    @Test("readings under 2 minutes apart are averaged, stale data gives no status") func duplicatesAndStale() throws {
        var r = Self.readings([(0, 120), (5, 116), (10, 112), (15, 108)])
        r.insert(AAPSHistory.Glucose(time: r[1].time - 30000, value: 114), at: 2)
        let gs = try #require(AAPSGlucoseStatusCalculator.glucoseStatus(
            buckets: AAPSGlucoseStatusCalculator.bucketedData(r), now: Self.now
        ))
        #expect(gs.delta == 5) // 120 - (116 + 114) / 2
        #expect(AAPSGlucoseStatusCalculator.glucoseStatus(
            buckets: AAPSGlucoseStatusCalculator.bucketedData(r), now: Self.now + 8 * Self.minute
        ) == nil)
    }

    // MARK: - COB

    static func flatHistory(carbsAt: Int64?, grams: Double = 30) -> AAPSHistory {
        var h = AAPSHistory()
        h.basalSchedule = [.init(minutes: 0, rate: 1.0)]
        h.glucose = (0 ..< 120).map { k in .init(time: Self.now - 30000 - Int64(k) * 5 * Self.minute, value: 100) }
        if let carbsAt { h.carbs = [.init(time: carbsAt, amount: grams)] }
        return h
    }

    static func meal(_ h: AAPSHistory, settings: AAPSMealCalculator.Settings = .init()) -> AAPSMealData {
        let table = AAPSMealCalculator.autosensTable(
            history: h, buckets: AAPSGlucoseStatusCalculator.bucketedData(h.glucose) ?? [], now: Self.now,
            curve: Self.curve, isfForCarbs: { _ in 50 }, carbRatio: { _ in 10 }, settings: settings, calendar: Self.utc
        )
        return AAPSMealCalculator.mealData(history: h, table: table, now: Self.now, settings: settings)
    }

    @Test("flat glucose absorbs carbs at the minimum carb impact") func minimumAbsorption() {
        let m = Self.meal(Self.flatHistory(carbsAt: Self.now - 60 * Self.minute))
        // added at the bucket 60 min ago, then 11 buckets of 8 x 10 / 50 = 1.6 g each
        #expect(abs(m.mealCOB - (30 - 11 * 1.6)) < 1E-9)
        #expect(m.carbs == 30)
        #expect(m.lastCarbTime == Self.now - 60 * Self.minute)
        #expect(m.slopeFromMaxDeviation == 0)
        #expect(m.slopeFromMinDeviation == 0)
    }

    @Test("carbs past the absorption cut-off drop out") func absorptionCutoff() {
        let m = Self.meal(Self.flatHistory(carbsAt: Self.now - 7 * 60 * Self.minute, grams: 200))
        #expect(m.mealCOB == 0)
        #expect(m.carbs == 0)
        let longer = Self.meal(
            Self.flatHistory(carbsAt: Self.now - 7 * 60 * Self.minute, grams: 200),
            settings: .init(min5mCarbImpact: 8, absorptionCutoffHours: 8)
        )
        #expect(longer.mealCOB > 0)
    }

    // MARK: - Carb ISF cache

    @Test("carb ISF is the mean of one value per 30-minute slot and glucose over 24 h") func carbIsfCache() {
        var cache = AAPSCarbIsfCache()
        let slot = Self.now - Self.now % (30 * Self.minute)
        cache.record(time: slot + 2 * Self.minute, glucose: 120, variableSensitivity: 30)
        cache.record(time: slot + 7 * Self.minute, glucose: 120, variableSensitivity: 32) // same key, replaces
        cache.record(time: slot + 12 * Self.minute, glucose: 140.6, variableSensitivity: 28)
        cache.record(time: slot - 25 * 3_600_000, glucose: 100, variableSensitivity: 99) // outside the 24 h window
        cache.record(time: slot + 13 * Self.minute, glucose: 141, variableSensitivity: 0) // ignored
        #expect(AAPSCarbIsfCache.key(time: slot + 12 * Self.minute, glucose: 140.6) == slot + 140)
        #expect(cache.average(upTo: slot + 15 * Self.minute) == 30)
        #expect(cache.average(upTo: slot + 130) == 32) // only the 120 key is at or before this time
        #expect(cache.average(upTo: slot - 1) == nil)
    }

    @Test("starting TDD stands in for missing days of the 7-day average") func startingTDD() {
        let now = Date(timeIntervalSince1970: Double(Self.now) / 1000)
        let today = Self.utc.startOfDay(for: now)
        // three real days, ending at today's midnight and the two before
        let records = (0 ..< 3).map { k in
            (date: Self.utc.date(byAdding: .day, value: -k, to: today)!, total: 100.0)
        }

        let none = AAPSTddSources.dailyTotals(records: records, now: now, calendar: Self.utc)
        #expect(none.tdd1D == 100)
        #expect(none.tdd7D == nil)

        let seeded = AAPSTddSources.dailyTotals(records: records, now: now, calendar: Self.utc, startingTDD: 78)
        #expect(seeded.tdd1D == 100)
        #expect(abs((seeded.tdd7D ?? 0) - (3 * 100 + 4 * 78) / 7.0) < 1E-9)

        // no history at all: every day is the stand-in
        let empty = AAPSTddSources.dailyTotals(records: [], now: now, calendar: Self.utc, startingTDD: 78)
        #expect(empty.tdd1D == 78)
        #expect(empty.tdd7D == 78)

        // seven real days: the stand-in is not used
        let full = (0 ..< 7).map { k in (date: Self.utc.date(byAdding: .day, value: -k, to: today)!, total: 90.0) }
        #expect(AAPSTddSources.dailyTotals(records: full, now: now, calendar: Self.utc, startingTDD: 78).tdd7D == 90)
    }
}
