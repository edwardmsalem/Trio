import Foundation
import Testing
@testable import Trio

/// Do Trio's own dosing inputs match the ones AAPS fed its calculation?
///
/// Rebuilds each logged AAPS loop run's treatment history and glucose readings from the private
/// Nightscout pulls, computes IOB, meal data and glucose status with Trio's code, and compares
/// them with what AAPS logged. Then it reruns the AAPS dosing port with Trio's inputs in place of
/// AAPS's and counts the doses that change.
///
/// Personal health data, never committed. Set `AAPS_ORACLE_DIR` (through xcodebuild,
/// `TEST_RUNNER_AAPS_ORACLE_DIR`). Without it the test skips. The basal and ISF schedules are
/// local times, so the process must run in Eddie's zone, America/New_York (through xcodebuild,
/// `TEST_RUNNER_TZ=America/New_York`). `AAPS_INPUTS_OUT` names a file
/// for the per-run rows (keep it inside the private folder).
@Suite("AAPS dosing inputs from Trio's own code (private data)", .serialized) struct AAPSInputsTests {
    static var ready: Bool {
        AAPSEquivalence.jsonlURL() != nil && AAPSInputs.nsDirectory() != nil
            && TimeZone.current.identifier == "America/New_York"
    }

    @Test(
        "Trio's IOB, meal data and glucose status against AAPS's logged inputs",
        .enabled(if: AAPSInputsTests.ready, "set AAPS_ORACLE_DIR to the private oracle folder and TZ to America/New_York")
    ) func trioInputsAgainstAAPS() throws {
        let env = ProcessInfo.processInfo.environment
        let records = try AAPSEquivalence.loadRecords(from: #require(AAPSEquivalence.jsonlURL()))
        let history = try AAPSInputs.loadHistory(from: #require(AAPSInputs.nsDirectory()))
        let tiers = AAPSEquivalence.tiers(seenIn: records)
        let stride = Int(env["AAPS_INPUTS_STRIDE"] ?? "1") ?? 1

        var iob0 = AAPSInputs.Stat(name: "IOB now", tolerance: 0.05)
        var iob0AapsRatio = AAPSInputs.Stat(name: "IOB now (Trio code, AAPS autosens ratio)", tolerance: 0.05)
        var act0 = AAPSInputs.Stat(name: "activity now", tolerance: 0.0005)
        var iobArray = AAPSInputs.Stat(name: "IOB array, every tick", tolerance: 0.05)
        var ztArray = AAPSInputs.Stat(name: "IOB with zero temp, every tick", tolerance: 0.05)
        var lastBolus = AAPSInputs.Stat(name: "last bolus time (min)", tolerance: 0)
        var cob = AAPSInputs.Stat(name: "COB", tolerance: 1)
        var carbs = AAPSInputs.Stat(name: "carbs", tolerance: 0)
        var lastCarb = AAPSInputs.Stat(name: "last carb time (min)", tolerance: 0)
        var slopeMax = AAPSInputs.Stat(name: "slope from max deviation", tolerance: 0.1)
        var slopeMin = AAPSInputs.Stat(name: "slope from min deviation", tolerance: 0.1)
        var glucose = AAPSInputs.Stat(name: "glucose", tolerance: 0)
        var delta = AAPSInputs.Stat(name: "delta", tolerance: 0.5)
        var shortAvg = AAPSInputs.Stat(name: "short avg delta", tolerance: 0.5)
        var longAvg = AAPSInputs.Stat(name: "long avg delta", tolerance: 0.5)
        var autosens = AAPSInputs.Stat(name: "autosens ratio (Trio autosens vs AAPS logged)", tolerance: 0.05)

        var doses = (all: 0, iob: 0, meal: 0, gs: 0, n: 0)
        var rows: [[String: Any]] = []
        var failures = 0

        for (index, r) in records.enumerated() where index % stride == 0 {
            let clock = r.iobArray.first?.time ?? r.ts
            let t: AAPSInputs.TrioComputed
            do { t = try AAPSInputs.trioInputs(history: history, clock: clock) } catch {
                failures += 1
                continue
            }
            let tAapsRatio = try AAPSInputs.trioInputs(history: history, clock: clock, autosensRatio: r.autosens.ratio)

            iob0.diffs.append(t.iob[0].iob - r.iobArray[0].iob)
            iob0AapsRatio.diffs.append(tAapsRatio.iob[0].iob - r.iobArray[0].iob)
            act0.diffs.append(t.iob[0].activity - r.iobArray[0].activity)
            for k in 0 ..< min(t.iob.count, r.iobArray.count) {
                iobArray.diffs.append(t.iob[k].iob - r.iobArray[k].iob)
                ztArray.diffs.append((t.iob[k].iobWithZeroTemp?.iob ?? 0) - (r.iobArray[k].iobWithZeroTemp?.iob ?? 0))
            }
            lastBolus.diffs.append(Double(t.iob[0].lastBolusTime - r.iobArray[0].lastBolusTime) / 60000)
            cob.diffs.append(t.meal.mealCOB - r.meal.mealCOB)
            carbs.diffs.append(t.meal.carbs - r.meal.carbs)
            lastCarb.diffs.append(Double(t.meal.lastCarbTime - r.meal.lastCarbTime) / 60000)
            slopeMax.diffs.append(t.meal.slopeFromMaxDeviation - r.meal.slopeFromMaxDeviation)
            slopeMin.diffs.append(t.meal.slopeFromMinDeviation - r.meal.slopeFromMinDeviation)
            glucose.diffs.append(t.glucoseStatus.glucose - r.glucoseStatus.glucose)
            delta.diffs.append(t.glucoseStatus.delta - r.glucoseStatus.delta)
            shortAvg.diffs.append(t.glucoseStatus.shortAvgDelta - r.glucoseStatus.shortAvgDelta)
            longAvg.diffs.append(t.glucoseStatus.longAvgDelta - r.glucoseStatus.longAvgDelta)
            autosens.diffs.append(t.trioAutosensRatio - r.autosens.ratio)

            let base = AAPSEquivalence.run(r, tiers: tiers)
            let withAll = AAPSEquivalence.run(
                AAPSInputs.record(r, iob: t.iob, meal: t.meal, glucoseStatus: t.glucoseStatus), tiers: tiers
            )
            let withIob = AAPSEquivalence.run(AAPSInputs.record(r, iob: t.iob), tiers: tiers)
            let withMeal = AAPSEquivalence.run(AAPSInputs.record(r, meal: t.meal), tiers: tiers)
            let withGs = AAPSEquivalence.run(AAPSInputs.record(r, glucoseStatus: t.glucoseStatus), tiers: tiers)
            doses.n += 1
            if AAPSInputs.sameDose(base, withAll) { doses.all += 1 }
            if AAPSInputs.sameDose(base, withIob) { doses.iob += 1 }
            if AAPSInputs.sameDose(base, withMeal) { doses.meal += 1 }
            if AAPSInputs.sameDose(base, withGs) { doses.gs += 1 }

            rows.append([
                "ts": r.ts,
                "iob": [r.iobArray[0].iob, t.iob[0].iob, tAapsRatio.iob[0].iob],
                "zt": [r.iobArray.map { $0.iobWithZeroTemp?.iob ?? 0 }, t.iob.map { $0.iobWithZeroTemp?.iob ?? 0 }],
                "cob": [r.meal.mealCOB, t.meal.mealCOB],
                "carbs": [r.meal.carbs, t.meal.carbs],
                "lastCarbTime": [r.meal.lastCarbTime, t.meal.lastCarbTime],
                "slopeMax": [r.meal.slopeFromMaxDeviation, t.meal.slopeFromMaxDeviation],
                "slopeMin": [r.meal.slopeFromMinDeviation, t.meal.slopeFromMinDeviation],
                "gs": [
                    [r.glucoseStatus.glucose, r.glucoseStatus.delta, r.glucoseStatus.shortAvgDelta, r.glucoseStatus.longAvgDelta],
                    [t.glucoseStatus.glucose, t.glucoseStatus.delta, t.glucoseStatus.shortAvgDelta, t.glucoseStatus.longAvgDelta]
                ],
                "autosens": [r.autosens.ratio, t.trioAutosensRatio],
                "dose": [
                    [base.units ?? -1, base.rate ?? -1, Double(base.duration ?? -1)],
                    [withAll.units ?? -1, withAll.rate ?? -1, Double(withAll.duration ?? -1)],
                    [withIob.units ?? -1, withIob.rate ?? -1, Double(withIob.duration ?? -1)],
                    [withMeal.units ?? -1, withMeal.rate ?? -1, Double(withMeal.duration ?? -1)],
                    [withGs.units ?? -1, withGs.rate ?? -1, Double(withGs.duration ?? -1)]
                ]
            ])
        }

        let lines = [
            iob0,
            iob0AapsRatio,
            act0,
            iobArray,
            ztArray,
            lastBolus,
            cob,
            carbs,
            lastCarb,
            slopeMax,
            slopeMin,
            glucose,
            delta,
            shortAvg,
            longAvg,
            autosens
        ].map(\.description)
        print("Trio stock inputs vs AAPS logged inputs (runs \(doses.n), skipped \(failures))\n" + lines.joined(separator: "\n"))
        print("""
        doses identical to AAPS when Trio supplies the inputs:
          all Trio inputs \(doses.all)/\(doses.n)
          Trio IOB only \(doses.iob)/\(doses.n)
          Trio meal data only \(doses.meal)/\(doses.n)
          Trio glucose status only \(doses.gs)/\(doses.n)
        """)
        if let out = env["AAPS_INPUTS_OUT"] {
            let data = try JSONSerialization.data(withJSONObject: rows)
            try data.write(to: URL(fileURLWithPath: out))
        }
        #expect(doses.n > 0)
    }

    @Test(
        "AAPS-mode inputs (AAPS IOB, COB and glucose-status ports on Trio's data) against AAPS's logged inputs",
        .enabled(if: AAPSInputsTests.ready, "set AAPS_ORACLE_DIR to the private oracle folder and TZ to America/New_York")
    ) func aapsModeInputsAgainstAAPS() throws {
        let env = ProcessInfo.processInfo.environment
        let records = try AAPSEquivalence.loadRecords(from: #require(AAPSEquivalence.jsonlURL()))
        let nsDir = try #require(AAPSInputs.nsDirectory())
        let history = try AAPSInputs.loadHistory(from: nsDir)
        let logged = try AAPSInputs.loadLoggedSens(from: nsDir)
        let tiers = AAPSEquivalence.tiers(seenIn: records)
        let stride = Int(env["AAPS_INPUTS_STRIDE"] ?? "1") ?? 1
        let curve = AAPSIob.Curve(diaHours: 5, peakMinutes: 75)

        var iob0 = AAPSInputs.Stat(name: "IOB now", tolerance: 0.001)
        var act0 = AAPSInputs.Stat(name: "activity now", tolerance: 0.0001)
        var iobArray = AAPSInputs.Stat(name: "IOB array, every tick", tolerance: 0.001)
        var ztArray = AAPSInputs.Stat(name: "IOB with zero temp, every tick", tolerance: 0.001)
        var ztAct = AAPSInputs.Stat(name: "zero-temp activity, every tick", tolerance: 0.0001)
        var lastBolus = AAPSInputs.Stat(name: "last bolus time (min)", tolerance: 0)
        var glucose = AAPSInputs.Stat(name: "glucose", tolerance: 0)
        var delta = AAPSInputs.Stat(name: "delta", tolerance: 0.01)
        var shortAvg = AAPSInputs.Stat(name: "short avg delta", tolerance: 0.01)
        var longAvg = AAPSInputs.Stat(name: "long avg delta", tolerance: 0.01)
        var gsDate = AAPSInputs.Stat(name: "glucose date (s)", tolerance: 5)
        var carbs = AAPSInputs.Stat(name: "carbs", tolerance: 0)
        var lastCarb = AAPSInputs.Stat(name: "last carb time (min)", tolerance: 0)

        enum Sens: String, CaseIterable { case logged, cache, rolling24h, current, profile }
        var cob: [Sens: AAPSInputs.Stat] = [:]
        var slopeMax: [Sens: AAPSInputs.Stat] = [:]
        var slopeMin: [Sens: AAPSInputs.Stat] = [:]
        var doseAll: [Sens: Int] = [:]
        var doseMeal: [Sens: Int] = [:]
        for s in Sens.allCases {
            cob[s] = AAPSInputs.Stat(name: "COB (\(s.rawValue) ISF)", tolerance: 0.5)
            slopeMax[s] = AAPSInputs.Stat(name: "slope from max deviation (\(s.rawValue) ISF)", tolerance: 0.05)
            slopeMin[s] = AAPSInputs.Stat(name: "slope from min deviation (\(s.rawValue) ISF)", tolerance: 0.05)
        }
        var doses = (iob: 0, gs: 0, n: 0)
        var rows: [[String: Any]] = []
        var readingNotYetReceived = 0

        for (index, r) in records.enumerated() where index % stride == 0 {
            let clock = r.iobArray.first?.time ?? r.ts
            // Readings AAPS had at the run: up to the newest one it logged.
            let newerInNightscout = history.readings.contains { $0.ms > r.glucoseStatus.date + 5000 && $0.ms <= clock }
            if newerInNightscout { readingNotYetReceived += 1 }
            let h = AAPSInputs.aapsHistory(history, clock: clock, glucoseUpTo: r.glucoseStatus.date + 5000)
            let iob = AAPSIob.iobArray(history: h, now: clock, autosensRatio: r.autosens.ratio, curve: curve)
            let buckets = AAPSGlucoseStatusCalculator.bucketedData(h.glucose)
            guard let gs = AAPSGlucoseStatusCalculator.glucoseStatus(buckets: buckets, now: clock) else { continue }

            iob0.diffs.append(iob[0].iob - r.iobArray[0].iob)
            act0.diffs.append(iob[0].activity - r.iobArray[0].activity)
            for k in 0 ..< min(iob.count, r.iobArray.count) {
                iobArray.diffs.append(iob[k].iob - r.iobArray[k].iob)
                ztArray.diffs.append((iob[k].iobWithZeroTemp?.iob ?? 0) - (r.iobArray[k].iobWithZeroTemp?.iob ?? 0))
                ztAct.diffs.append((iob[k].iobWithZeroTemp?.activity ?? 0) - (r.iobArray[k].iobWithZeroTemp?.activity ?? 0))
            }
            lastBolus.diffs.append(Double(iob[0].lastBolusTime - r.iobArray[0].lastBolusTime) / 60000)
            glucose.diffs.append(gs.glucose - r.glucoseStatus.glucose)
            delta.diffs.append(gs.delta - r.glucoseStatus.delta)
            shortAvg.diffs.append(gs.shortAvgDelta - r.glucoseStatus.shortAvgDelta)
            longAvg.diffs.append(gs.longAvgDelta - r.glucoseStatus.longAvgDelta)
            gsDate.diffs.append(Double(gs.date - r.glucoseStatus.date) / 1000)
            if env["AAPS_DEBUG_GS"] != nil, gs.glucose != r.glucoseStatus.glucose || gs.delta != r.glucoseStatus.delta
                || gs.shortAvgDelta != r.glucoseStatus.shortAvgDelta || gs.longAvgDelta != r.glucoseStatus.longAvgDelta
            {
                let near = h.glucose.prefix(10).map { "\(($0.time - clock) / 1000)s:\(Int($0.value))" }.joined(separator: " ")
                let b = (buckets ?? []).prefix(10).map { "\(($0.time - clock) / 1000)s:\(Int($0.value))" }.joined(separator: " ")
                print(
                    "GS ts=\(r.ts) logged \(r.glucoseStatus) port \(gs) loggedDate-clock \((r.glucoseStatus.date - clock) / 1000)s five=\(AAPSGlucoseStatusCalculator.isAbout5minData(h.glucose))\n  readings \(near)\n  buckets  \(b)"
                )
            }

            let base = AAPSEquivalence.run(r, tiers: tiers)
            doses.n += 1
            if AAPSInputs.sameDose(base, AAPSEquivalence.run(AAPSInputs.record(r, iob: iob), tiers: tiers)) { doses.iob += 1 }
            if AAPSInputs
                .sameDose(base, AAPSEquivalence.run(AAPSInputs.record(r, glucoseStatus: gs), tiers: tiers)) { doses.gs += 1 }

            let variableSensNow = r.profile.variable_sens > 0 ? r.profile.variable_sens : r.profile.sens
            var row: [String: Any] = [
                "ts": r.ts,
                "cobLogged": r.meal.mealCOB,
                "slopes": [r.meal.slopeFromMaxDeviation, r.meal.slopeFromMinDeviation]
            ]
            let carbIsfCache = logged.cache(upTo: clock)
            for s in Sens.allCases {
                let isf: (Int64) -> Double = { t in
                    switch s {
                    case .logged: return logged.latest(atOrBefore: t).map { logged.isfForCarbs[$0] } ?? variableSensNow
                    case .rolling24h: return logged.averageVariableSens(upTo: t) ?? variableSensNow
                    case .cache: return carbIsfCache.average(upTo: t) ?? variableSensNow
                    case .current: return variableSensNow
                    case .profile:
                        let hour = Calendar.current.component(.hour, from: AAPSInputs.date(t))
                        return hour < 6 ? 21 : 25
                    }
                }
                let table = AAPSMealCalculator.autosensTable(
                    history: h, buckets: buckets ?? [], now: clock, curve: curve, isfForCarbs: isf, carbRatio: { _ in 7 }
                )
                let meal = AAPSMealCalculator.mealData(history: h, table: table, now: clock)
                if s == .logged {
                    carbs.diffs.append(meal.carbs - r.meal.carbs)
                    lastCarb.diffs.append(Double(meal.lastCarbTime - r.meal.lastCarbTime) / 60000)
                }
                cob[s]!.diffs.append(meal.mealCOB - r.meal.mealCOB)
                slopeMax[s]!.diffs.append(meal.slopeFromMaxDeviation - r.meal.slopeFromMaxDeviation)
                slopeMin[s]!.diffs.append(meal.slopeFromMinDeviation - r.meal.slopeFromMinDeviation)
                if AAPSInputs.sameDose(base, AAPSEquivalence.run(AAPSInputs.record(r, meal: meal), tiers: tiers)) {
                    doseMeal[s, default: 0] += 1
                }
                if AAPSInputs.sameDose(
                    base, AAPSEquivalence.run(AAPSInputs.record(r, iob: iob, meal: meal, glucoseStatus: gs), tiers: tiers)
                ) { doseAll[s, default: 0] += 1 }
                row[s.rawValue] = [meal.mealCOB, meal.slopeFromMaxDeviation, meal.slopeFromMinDeviation, meal.carbs]
            }
            row["iob"] = [r.iobArray[0].iob, iob[0].iob]
            row["gs"] =
                [
                    [r.glucoseStatus.glucose, r.glucoseStatus.delta, r.glucoseStatus.shortAvgDelta, r.glucoseStatus.longAvgDelta],
                    [gs.glucose, gs.delta, gs.shortAvgDelta, gs.longAvgDelta]
                ]
            rows.append(row)
        }

        var lines = [iob0, act0, iobArray, ztArray, ztAct, lastBolus, glucose, delta, shortAvg, longAvg, gsDate, carbs, lastCarb]
            .map(\.description)
        for s in Sens.allCases { lines += [cob[s]!, slopeMax[s]!, slopeMin[s]!].map(\.description) }
        print("AAPS-mode inputs vs AAPS logged inputs (runs \(doses.n))\n" + lines.joined(separator: "\n"))
        print("runs where Nightscout holds a reading AAPS had not received yet: \(readingNotYetReceived)")
        print("doses identical: AAPS-mode IOB only \(doses.iob)/\(doses.n), glucose status only \(doses.gs)/\(doses.n)")
        for s in Sens.allCases {
            print(
                "  ISF for carbs = \(s.rawValue): meal only \(doseMeal[s] ?? 0)/\(doses.n), all inputs \(doseAll[s] ?? 0)/\(doses.n)"
            )
        }
        if let out = env["AAPS_MODE_OUT"] {
            try JSONSerialization.data(withJSONObject: rows).write(to: URL(fileURLWithPath: out))
        }
        #expect(doses.n > 0)
    }
}
