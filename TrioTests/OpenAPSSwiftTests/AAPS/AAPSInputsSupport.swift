import Foundation
@testable import Trio

/// Rebuilds the treatment history and glucose readings behind each logged AAPS loop run from the
/// Nightscout pulls in the private oracle folder (`ns/entries_*.json`, `ns/treatments_*.json`),
/// feeds them through Trio's own IOB, meal and glucose-status code, and compares the results
/// with the inputs AAPS logged for the same run.
///
/// The data is personal health data and is never committed. Without `AAPS_ORACLE_DIR` the tests
/// that use this skip.
enum AAPSInputs {
    // MARK: - History

    struct Bolus {
        let ms: Int64
        let amount: Double
        let smb: Bool
    }

    struct Temp {
        let ms: Int64
        var durationMs: Int64
        let rate: Double
    }

    struct Carb {
        let ms: Int64
        let amount: Double
    }

    struct Reading {
        let ms: Int64
        let sgv: Int
    }

    struct TT {
        let ms: Int64
        let durationMin: Double
        let target: Double
    }

    struct History {
        var boluses: [Bolus] = []
        var temps: [Temp] = []
        var carbs: [Carb] = []
        var readings: [Reading] = []
        var tempTargets: [TT] = []
    }

    static func nsDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        guard let dir = environment["AAPS_ORACLE_DIR"] else { return nil }
        let url = URL(fileURLWithPath: dir).appendingPathComponent("ns")
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: url.path),
              names.contains(where: { $0.hasPrefix("treatments_") }),
              names.contains(where: { $0.hasPrefix("entries_") })
        else { return nil }
        return url
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoNoFraction = ISO8601DateFormatter()

    static func millis(_ s: String) -> Int64? {
        guard let d = iso.date(from: s) ?? isoNoFraction.date(from: s) else { return nil }
        return Int64((d.timeIntervalSince1970 * 1000).rounded())
    }

    private static func num(_ any: Any?) -> Double? { (any as? NSNumber)?.doubleValue }

    static func loadHistory(from dir: URL) throws -> History {
        let fm = FileManager.default
        let names = try fm.contentsOfDirectory(atPath: dir.path).sorted()
        var treatments: [[String: Any]] = []
        var entries: [[String: Any]] = []
        for name in names where name.hasSuffix(".json") {
            let data = try Data(contentsOf: dir.appendingPathComponent(name))
            let rows = (try JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
            if name.hasPrefix("treatments_") { treatments += rows }
            if name.hasPrefix("entries_") { entries += rows }
        }

        var boluses: [String: Bolus] = [:]
        var temps: [String: Temp] = [:]
        var carbs = Set<[Int64]>()
        var tts: [TT] = []
        for t in treatments {
            if (t["isValid"] as? NSNumber)?.boolValue == false { continue }
            let type = t["eventType"] as? String ?? ""
            let key = (t["pumpId"] as? NSNumber)?.stringValue ?? (t["_id"] as? String ?? UUID().uuidString)
            let created = (t["created_at"] as? String).flatMap(millis)
            if let insulin = num(t["insulin"]), insulin > 0, ["Correction Bolus", "Meal Bolus", "Bolus"].contains(type),
               let ms = (t["date"] as? NSNumber)?.int64Value ?? created
            {
                boluses[key] = Bolus(ms: ms, amount: insulin, smb: (t["isSMB"] as? NSNumber)?.boolValue ?? false)
            }
            if type == "Temp Basal", let ms = created, let dur = (t["durationInMilliseconds"] as? NSNumber)?.int64Value,
               let rate = num(t["absolute"]) ?? num(t["rate"])
            {
                temps[key] = Temp(ms: ms, durationMs: dur, rate: rate)
            }
            if let c = num(t["carbs"]), c > 0, let ms = (t["date"] as? NSNumber)?.int64Value ?? created {
                carbs.insert([ms, Int64((c * 1000).rounded())])
            }
            if type == "Temporary Target", let ms = (t["timestamp"] as? NSNumber)?.int64Value ?? created,
               let dur = num(t["duration"]), let low = num(t["targetBottom"]), let high = num(t["targetTop"])
            {
                tts.append(TT(ms: ms, durationMin: dur, target: (low + high) / 2))
            }
        }

        var tempList = temps.values.sorted { $0.ms < $1.ms }
        // AAPS keeps one temp basal at a time: a new temp ends the one before it. Nightscout keeps
        // the planned duration on some superseded temps, so cut them here.
        for i in tempList.indices.dropLast() where tempList[i].ms + tempList[i].durationMs > tempList[i + 1].ms {
            tempList[i].durationMs = tempList[i + 1].ms - tempList[i].ms
        }

        // xDrip and AAPS both upload each reading. Keep one per reading.
        let rawReadings = entries.compactMap { e -> Reading? in
            guard let ms = (e["date"] as? NSNumber)?.int64Value, let sgv = num(e["sgv"]) else { return nil }
            return Reading(ms: ms, sgv: Int(sgv))
        }.sorted { $0.ms < $1.ms }
        var readings: [Reading] = []
        for r in rawReadings {
            if let last = readings.last, r.ms - last.ms < 120_000 { continue }
            readings.append(r)
        }

        return History(
            boluses: boluses.values.sorted { $0.ms < $1.ms },
            temps: tempList,
            carbs: carbs.map { Carb(ms: $0[0], amount: Double($0[1]) / 1000) }.sorted { $0.ms < $1.ms },
            readings: readings,
            tempTargets: tts.sorted { $0.ms < $1.ms }
        )
    }

    // MARK: - Trio inputs

    static func date(_ ms: Int64) -> Date { Date(timeIntervalSince1970: Double(ms) / 1000) }

    private static func dec(_ x: Double) -> Decimal { Decimal(string: "\(x)") ?? Decimal(x) }

    /// Eddie's AAPS profile in Trio's terms: DIA 5 h, Rapid-Acting curve (peak 75), basal 1.3 U/h
    /// from midnight and 1.0 from 07:00, ISF 21 then 25 from 06:00, carb ratio 7, 6 h absorption,
    /// minimum carb impact 8 (AAPS openaps_smb_min_5m_carbimpact).
    static func trioProfile() -> Profile {
        var p = Profile()
        p.dia = 5
        p.curve = .rapidActing
        p.useCustomPeakTime = false
        p.insulinPeakTime = 75
        p.min5mCarbImpact = 8
        p.maxCOB = 120
        p.maxMealAbsorptionTime = 6
        p.carbRatio = 7
        p.carbRatios = CarbRatios(units: .grams, schedule: [CarbRatioEntry(start: "00:00:00", offset: 0, ratio: 7)])
        p.basalprofile = basalProfile()
        p.currentBasal = 1
        p.maxDailyBasal = 1.3
        p.isfProfile = ComputedInsulinSensitivities(
            units: .mgdL,
            userPreferredUnits: .mgdL,
            sensitivities: [
                ComputedInsulinSensitivityEntry(sensitivity: 21, offset: 0, start: "00:00:00"),
                ComputedInsulinSensitivityEntry(sensitivity: 25, offset: 360, start: "06:00:00")
            ]
        )
        p.sens = 25
        p.autosensMax = 1.2
        p.autosensMin = 0.7
        p.suspendZerosIob = true
        p.highTemptargetRaisesSensitivity = false
        p.outUnits = .mgdL
        return p
    }

    static func basalProfile() -> [BasalProfileEntry] {
        [
            BasalProfileEntry(start: "00:00:00", minutes: 0, rate: 1.3),
            BasalProfileEntry(start: "07:00:00", minutes: 420, rate: 1.0)
        ]
    }

    /// Trio's pump history for a loop run at `clock`: the last 24 hours, nothing after `clock`.
    static func pumpHistory(_ h: History, clock: Int64) -> [PumpHistoryEvent] {
        let from = clock - 24 * 3_600_000
        var events: [PumpHistoryEvent] = []
        for b in h.boluses where b.ms >= from && b.ms <= clock {
            events.append(PumpHistoryEvent(
                id: "b\(b.ms)", type: .bolus, timestamp: date(b.ms), amount: dec(b.amount), isSMB: b.smb
            ))
        }
        for t in h.temps where t.ms >= from && t.ms <= clock {
            // Trio records whole minutes. A temp still running at the loop run keeps its full
            // length here, and Trio's own zero temp at clock + 1 min ends it, as on the phone.
            let minutes = Int((Double(t.durationMs) / 60000).rounded())
            events.append(PumpHistoryEvent(
                id: "t\(t.ms)", type: .tempBasal, timestamp: date(t.ms), rate: dec(t.rate), temp: .absolute
            ))
            events.append(PumpHistoryEvent(
                id: "d\(t.ms)", type: .tempBasalDuration, timestamp: date(t.ms), durationMin: minutes
            ))
        }
        return events.sorted { $0.timestamp > $1.timestamp }
    }

    static func carbs(_ h: History, clock: Int64) -> [CarbsEntry] {
        h.carbs.filter { $0.ms >= clock - 24 * 3_600_000 && $0.ms <= clock }.map {
            CarbsEntry(
                id: "c\($0.ms)", createdAt: date($0.ms), actualDate: date($0.ms), carbs: dec($0.amount),
                fat: 0, protein: 0, note: nil, enteredBy: CarbsEntry.local, isFPU: false, fpuID: nil
            )
        }
    }

    /// Newest first, as Trio's glucose storage returns them.
    static func glucose(_ h: History, clock: Int64, hours: Double) -> [BloodGlucose] {
        let from = clock - Int64(hours * 3_600_000)
        return h.readings.filter { $0.ms > from && $0.ms <= clock }.reversed().map {
            BloodGlucose(sgv: $0.sgv, date: Decimal($0.ms), dateString: date($0.ms), glucose: $0.sgv, type: "sgv")
        }
    }

    static func tempTargets(_ h: History, clock: Int64) -> [TempTarget] {
        h.tempTargets.filter { $0.ms <= clock && $0.ms >= clock - 24 * 3_600_000 }.map {
            TempTarget(
                name: nil, createdAt: date($0.ms), targetTop: dec($0.target), targetBottom: dec($0.target),
                duration: dec($0.durationMin), enteredBy: nil, reason: nil, isPreset: nil, enabled: nil,
                halfBasalTarget: nil
            )
        }
    }

    struct TrioComputed {
        var iob: [AAPSIobTotal]
        var meal: AAPSMealData
        var glucoseStatus: AAPSGlucoseStatus
        var trioAutosensRatio: Double
    }

    private static func dbl(_ d: Decimal) -> Double { Double(truncating: d as NSNumber) }

    /// What Trio's stock code computes for this run, mapped the way `AAPSDosingAdapter` maps it.
    static func trioInputs(
        history h: History,
        clock: Int64,
        autosensRatio: Double? = nil,
        profile: Profile = trioProfile()
    ) throws -> TrioComputed {
        let pumpHistory = pumpHistory(h, clock: clock)
        let carbs = carbs(h, clock: clock)
        let glucose = glucose(h, clock: clock, hours: 6.5)
        let now = date(clock)

        let ratio = try autosensRatio ?? trioAutosens(history: h, clock: clock, profile: profile)
        let autosens = Autosens(ratio: dec(ratio), newisf: nil)
        let iob = try IobGenerator.generate(
            history: pumpHistory.removingDuplicateSuspendResumeEvents(),
            profile: profile,
            clock: now,
            autosens: autosens
        )
        let meal = try MealGenerator.generate(
            pumpHistory: pumpHistory,
            profile: profile,
            basalProfile: basalProfile(),
            clock: now,
            carbHistory: carbs,
            glucoseHistory: glucose
        )
        guard let gs = try DeterminationGenerator.getGlucoseStatus(glucoseReadings: glucose), let meal else {
            throw NSError(domain: "AAPSInputs", code: 1)
        }
        let iobArray = iob.enumerated().map { index, tick in
            AAPSIobTotal(
                time: Int64(tick.time.timeIntervalSince1970 * 1000),
                iob: dbl(tick.iob),
                activity: dbl(tick.activity),
                lastBolusTime: index == 0 ? Int64(iob[0].lastBolusTime ?? 0) : 0,
                iobWithZeroTemp: AAPSIobTotal.ZeroTemp(
                    iob: dbl(tick.iobWithZeroTemp.iob),
                    activity: dbl(tick.iobWithZeroTemp.activity)
                )
            )
        }
        return TrioComputed(
            iob: iobArray,
            meal: AAPSMealData(
                carbs: dbl(meal.carbs),
                mealCOB: dbl(meal.mealCOB),
                slopeFromMaxDeviation: dbl(meal.slopeFromMaxDeviation),
                slopeFromMinDeviation: dbl(meal.slopeFromMinDeviation),
                lastBolusTime: 0,
                lastCarbTime: Int64(meal.lastCarbTime)
            ),
            glucoseStatus: AAPSGlucoseStatus(
                glucose: dbl(gs.glucose),
                noise: Double(gs.noise),
                delta: dbl(gs.delta),
                shortAvgDelta: dbl(gs.shortAvgDelta),
                longAvgDelta: dbl(gs.longAvgDelta),
                date: Int64(gs.date.timeIntervalSince1970 * 1000)
            ),
            trioAutosensRatio: ratio
        )
    }

    /// Trio's autosens ratio as `OpenAPS.autosense` computes it: the lower of the 8 h and 24 h runs.
    static func trioAutosens(history h: History, clock: Int64, profile: Profile) throws -> Double {
        let glucose = glucose(h, clock: clock, hours: 24)
        let pumpHistory = pumpHistory(h, clock: clock)
        let carbs = carbs(h, clock: clock)
        let tts = tempTargets(h, clock: clock)
        let now = date(clock)
        let pre = glucose.count >= 72 ? try IobHistory.calcTempTreatments(
            history: pumpHistory.map { $0.computedEvent() }, profile: profile, clock: now, autosens: nil, zeroTempDuration: nil
        ) : nil
        let r8 = try AutosensGenerator.generate(
            glucose: glucose, pumpHistory: pumpHistory, basalProfile: basalProfile(), profile: profile, carbs: carbs,
            tempTargets: tts, maxDeviations: 96, clock: now, precomputedTreatments: pre
        )
        let r24 = try AutosensGenerator.generate(
            glucose: glucose, pumpHistory: pumpHistory, basalProfile: basalProfile(), profile: profile, carbs: carbs,
            tempTargets: tts, maxDeviations: 288, clock: now, precomputedTreatments: pre
        )
        return dbl(min(r8.ratio, r24.ratio))
    }

    // MARK: - Comparison

    struct Stat: CustomStringConvertible {
        let name: String
        var diffs: [Double] = []
        var tolerance: Double

        var description: String {
            let n = diffs.count
            guard n > 0 else { return "\(name): no data" }
            let abs = diffs.map(Swift.abs)
            let exact = abs.filter { $0 < 1E-9 }.count
            let within = abs.filter { $0 <= tolerance + 1E-9 }.count
            let sorted = abs.sorted()
            let p95 = sorted[min(n - 1, Int(Double(n) * 0.95))]
            let mean = diffs.reduce(0, +) / Double(n)
            return "\(name): exact \(exact)/\(n), within \(tolerance) \(within)/\(n), mean diff \(fmt(mean)), p95 |diff| \(fmt(p95)), max |diff| \(fmt(sorted.last ?? 0))"
        }

        private func fmt(_ x: Double) -> String { String(format: "%.4f", x) }
    }

    /// Replaces the logged inputs of a run with other ones and returns the new record.
    static func record(
        _ r: AAPSEquivalence.Record,
        iob: [AAPSIobTotal]? = nil,
        meal: AAPSMealData? = nil,
        glucoseStatus: AAPSGlucoseStatus? = nil
    ) -> AAPSEquivalence.Record {
        AAPSEquivalence.Record(
            ts: r.ts,
            glucoseStatus: glucoseStatus ?? r.glucoseStatus,
            currentTemp: r.currentTemp,
            iobArray: iob ?? r.iobArray,
            profile: r.profile,
            autosens: r.autosens,
            meal: meal.map { var m = $0
                m.lastBolusTime = r.meal.lastBolusTime
                return m } ?? r.meal,
            microBolusAllowed: r.microBolusAllowed,
            flat: r.flat,
            dyn: r.dyn,
            onDynamic: r.onDynamic,
            logged: r.logged
        )
    }

    /// Same dose: SMB units, temp rate and temp duration.
    static func sameDose(_ a: AAPSResult, _ b: AAPSResult) -> Bool {
        func eq(_ x: Double?, _ y: Double?) -> Bool { (x == nil && y == nil) || (x != nil && y != nil && abs(x! - y!) < 1E-9) }
        return eq(a.units, b.units) && eq(a.rate, b.rate) && a.duration == b.duration
    }
}

// MARK: - AAPS-mode inputs

extension AAPSInputs {
    /// One logged value per AAPS loop run, from the Nightscout devicestatus pulls
    /// (`ns/ds_window_*.json`): the ISF AAPS used for carbs and the dynamic ISF of that run.
    struct LoggedSens {
        var times: [Int64] = []
        var isfForCarbs: [Double] = []
        var variableSens: [Double] = []
        var glucose: [Double] = []

        func latest(atOrBefore t: Int64) -> Int? {
            var lo = 0
            var hi = times.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if times[mid] <= t { lo = mid + 1 } else { hi = mid }
            }
            return lo == 0 ? nil : lo - 1
        }

        /// The carb ISF cache Trio's AAPS mode keeps, filled with the runs up to `t` (their dynamic
        /// ISF is AAPS's, which the Dynamic ISF equivalence test proves Trio computes the same).
        func cache(upTo t: Int64) -> AAPSCarbIsfCache {
            var cache = AAPSCarbIsfCache()
            guard let end = latest(atOrBefore: t) else { return cache }
            var k = end
            while k > 0, times[k - 1] >= t - 25 * 3_600_000 { k -= 1 }
            for i in k ... end {
                cache.record(time: times[i], glucose: glucose[i], variableSensitivity: variableSens[i])
            }
            return cache
        }

        /// Mean dynamic ISF of the loop runs in the 24 hours up to `t`.
        func averageVariableSens(upTo t: Int64) -> Double? {
            guard let end = latest(atOrBefore: t) else { return nil }
            var sum = 0.0
            var n = 0
            var k = end
            while k >= 0, times[k] >= t - 24 * 3_600_000 {
                if variableSens[k] > 0 { sum += variableSens[k]
                    n += 1 }
                k -= 1
            }
            return n == 0 ? nil : sum / Double(n)
        }
    }

    static func loadLoggedSens(from dir: URL) throws -> LoggedSens {
        var rows: [(Int64, Double, Double, Double)] = []
        for name in try FileManager.default.contentsOfDirectory(atPath: dir.path) where name.hasPrefix("ds_window_") {
            let data = try Data(contentsOf: dir.appendingPathComponent(name))
            for d in (try JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? [] {
                guard let s = (d["openaps"] as? [String: Any])?["suggested"] as? [String: Any],
                      let isf = (s["isfMgdlForCarbs"] as? NSNumber)?.doubleValue,
                      let ts = (s["timestamp"] as? String).flatMap(millis)
                else { continue }
                rows
                    .append((
                        ts,
                        isf,
                        (s["variable_sens"] as? NSNumber)?.doubleValue ?? 0,
                        (s["bg"] as? NSNumber)?.doubleValue ?? 0
                    ))
            }
        }
        rows.sort { $0.0 < $1.0 }
        var out = LoggedSens()
        for r in rows where out.times.last != r.0 {
            out.times.append(r.0)
            out.isfForCarbs.append(r.1)
            out.variableSens.append(r.2)
            out.glucose.append(r.3)
        }
        return out
    }

    /// Trio's data for the run turned into the AAPS view, the way the AAPS mode builds it.
    /// `glucoseUpTo` drops readings AAPS had not received yet at the loop run (Nightscout can hold
    /// a reading timed a few seconds before the run that reached AAPS after it).
    static func aapsHistory(_ h: History, clock: Int64, glucoseUpTo: Int64? = nil) -> AAPSHistory {
        AAPSHistory.from(
            pumpHistory: pumpHistory(h, clock: clock),
            carbs: carbs(h, clock: clock),
            glucose: glucose(h, clock: min(clock, glucoseUpTo ?? clock), hours: 29),
            basalProfile: basalProfile(),
            now: date(clock)
        )
    }
}
