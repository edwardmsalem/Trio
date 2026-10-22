import Foundation
#if !AAPS_CLI
    @testable import Trio
#endif

/// Replays logged AAPS loop runs (the JSONL that `tools/aaps-oracle/extract.py` writes) through
/// the Swift AAPS dosing core and compares every decision with what AAPS logged.
///
/// The data is personal health data and is never committed. Point `AAPS_ORACLE_DIR` (or
/// `AAPS_ORACLE_JSONL`) at the private folder. Without it the equivalence test skips.
enum AAPSEquivalence {
    struct Record {
        let ts: Int64
        let glucoseStatus: AAPSGlucoseStatus
        let currentTemp: AAPSCurrentTemp
        let iobArray: [AAPSIobTotal]
        let profile: AAPSOapsProfile
        let autosens: AAPSAutosensResult
        let meal: AAPSMealData
        let microBolusAllowed: Bool
        let flat: Bool
        let dyn: Bool
        let onDynamic: Bool
        let logged: [String: Any]
    }

    struct Mismatch {
        let ts: Int64
        let field: String
        let expected: String
        let actual: String
    }

    struct Report {
        var checked = 0
        var doseIdentical = 0
        var eventualExact = 0
        var eventualWithin1 = 0
        var insulinReqEqual = 0
        var unitsEqual = 0
        var tempEqual = 0
        var carbsReqEqual = 0
        var minGuardEqual = 0
        var minPredEqual = 0
        var dosingSensEqual = 0
        var branchEqual = 0
        var reasonExact = 0
        var predictionsEqual = 0
        var mismatches: [Mismatch] = []

        var summary: String {
            """
            checked \(checked)
            doses identical (SMB units + temp rate + temp duration): \(doseIdentical)
            eventual BG exact: \(eventualExact), within 1 mg/dL: \(eventualWithin1)
            insulinReq equal: \(insulinReqEqual)
            SMB units equal: \(unitsEqual)
            temp rate and duration equal: \(tempEqual)
            carbsReq equal: \(carbsReqEqual)
            minGuardBG equal: \(minGuardEqual)
            minPredBG equal: \(minPredEqual)
            dosing sensitivity equal: \(dosingSensEqual)
            decision branch equal: \(branchEqual)
            reason text identical: \(reasonExact)
            prediction curves identical: \(predictionsEqual)
            """
        }
    }

    // MARK: - Loading

    static func jsonlURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        let fm = FileManager.default
        var candidates: [String] = []
        if let file = environment["AAPS_ORACLE_JSONL"] { candidates.append(file) }
        if let dir = environment["AAPS_ORACLE_DIR"] { candidates.append((dir as NSString).appendingPathComponent("aps.jsonl")) }
        return candidates.lazy.map { URL(fileURLWithPath: $0) }.first { fm.fileExists(atPath: $0.path) }
    }

    private static func d(_ dict: [String: Any]?, _ key: String, _ def: Double = 0) -> Double {
        guard let v = dict?[key] else { return def }
        if let n = v as? NSNumber { return n.doubleValue }
        return def
    }

    private static func i(_ dict: [String: Any]?, _ key: String, _ def: Int = 0) -> Int {
        guard let n = dict?[key] as? NSNumber else { return def }
        return n.intValue
    }

    private static func l(_ dict: [String: Any]?, _ key: String) -> Int64 {
        guard let n = dict?[key] as? NSNumber else { return 0 }
        return n.int64Value
    }

    private static func b(_ dict: [String: Any]?, _ key: String) -> Bool {
        (dict?[key] as? NSNumber)?.boolValue ?? false
    }

    static func loadRecords(from url: URL) throws -> [Record] {
        let text = try String(contentsOf: url, encoding: .utf8)
        var records: [Record] = []
        for line in text.split(separator: "\n") where !line.isEmpty {
            guard let obj = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            records.append(record(from: obj))
        }
        return records.sorted { $0.ts < $1.ts }
    }

    static func record(from obj: [String: Any]) -> Record {
        let gs = obj["glucoseStatusJson"] as? [String: Any]
        let ct = obj["currentTempJson"] as? [String: Any]
        let iobs = obj["iobDataJson"] as? [[String: Any]] ?? []
        let p = obj["profileJson"] as? [String: Any]
        let ad = obj["autosensDataJson"] as? [String: Any]
        let meal = obj["mealDataJson"] as? [String: Any]
        let res = obj["resultJson"] as? [String: Any] ?? [:]
        let consoleError = res["consoleError"] as? [String] ?? []
        let consoleLog = res["consoleLog"] as? [String] ?? []

        let iobArray = iobs.map { t -> AAPSIobTotal in
            let zt = t["iobWithZeroTemp"] as? [String: Any]
            return AAPSIobTotal(
                time: l(t, "time"),
                iob: d(t, "iob"),
                activity: d(t, "activity"),
                lastBolusTime: l(t, "lastBolusTime"),
                iobWithZeroTemp: zt.map { AAPSIobTotal.ZeroTemp(iob: d($0, "iob"), activity: d($0, "activity")) }
            )
        }
        let profile = AAPSOapsProfile(
            max_iob: d(p, "max_iob"),
            max_daily_basal: d(p, "max_daily_basal"),
            max_basal: d(p, "max_basal"),
            min_bg: d(p, "min_bg"),
            max_bg: d(p, "max_bg"),
            target_bg: d(p, "target_bg"),
            carb_ratio: d(p, "carb_ratio"),
            sens: d(p, "sens"),
            max_daily_safety_multiplier: d(p, "max_daily_safety_multiplier"),
            current_basal_safety_multiplier: d(p, "current_basal_safety_multiplier"),
            high_temptarget_raises_sensitivity: b(p, "high_temptarget_raises_sensitivity"),
            low_temptarget_lowers_sensitivity: b(p, "low_temptarget_lowers_sensitivity"),
            sensitivity_raises_target: b(p, "sensitivity_raises_target"),
            resistance_lowers_target: b(p, "resistance_lowers_target"),
            adv_target_adjustments: b(p, "adv_target_adjustments"),
            exercise_mode: b(p, "exercise_mode"),
            half_basal_exercise_target: i(p, "half_basal_exercise_target", 160),
            skip_neutral_temps: b(p, "skip_neutral_temps"),
            remainingCarbsCap: i(p, "remainingCarbsCap", 90),
            enableUAM: b(p, "enableUAM"),
            SMBInterval: i(p, "SMBInterval", 3),
            enableSMB_with_COB: b(p, "enableSMB_with_COB"),
            enableSMB_with_temptarget: b(p, "enableSMB_with_temptarget"),
            allowSMB_with_high_temptarget: b(p, "allowSMB_with_high_temptarget"),
            enableSMB_always: b(p, "enableSMB_always"),
            enableSMB_after_carbs: b(p, "enableSMB_after_carbs"),
            maxSMBBasalMinutes: i(p, "maxSMBBasalMinutes", 30),
            maxUAMSMBBasalMinutes: i(p, "maxUAMSMBBasalMinutes", 30),
            bolus_increment: d(p, "bolus_increment", 0.1),
            carbsReqThreshold: i(p, "carbsReqThreshold", 1),
            current_basal: d(p, "current_basal"),
            temptargetSet: b(p, "temptargetSet"),
            autosens_max: d(p, "autosens_max", 1.2),
            lgsThreshold: (p?["lgsThreshold"] as? NSNumber)?.intValue,
            variable_sens: d(p, "variable_sens"),
            insulinDivisor: i(p, "insulinDivisor"),
            TDD: d(p, "TDD")
        )
        // A handful of runs are the first line of a log file, so the flags logged just before
        // them are missing. Recover them from the result itself.
        let dyn = (obj["dyn"] as? NSNumber)?.boolValue ?? ((res["runningDynamicIsf"] as? NSNumber)?.boolValue ?? false)
        let mba = (obj["mba"] as? NSNumber)?.boolValue ?? !consoleError.contains("SMB disabled (!microBolusAllowed)")
        let flat = (obj["flat"] as? NSNumber)?.boolValue ?? false
        // When a tier line is logged it names the order. The fork shipped "on top of dynamic".
        let onDynamic = !consoleLog.contains { $0.contains("(Trio order)") || $0.contains("cancelled by the dynamic formula") }
        return Record(
            ts: l(obj, "ts"),
            glucoseStatus: AAPSGlucoseStatus(
                glucose: d(gs, "glucose"),
                noise: d(gs, "noise"),
                delta: d(gs, "delta"),
                shortAvgDelta: d(gs, "shortAvgDelta"),
                longAvgDelta: d(gs, "longAvgDelta"),
                date: l(gs, "date")
            ),
            currentTemp: AAPSCurrentTemp(
                duration: i(ct, "duration"),
                rate: d(ct, "rate"),
                minutesrunning: (ct?["minutesrunning"] as? NSNumber)?.intValue
            ),
            iobArray: iobArray,
            profile: profile,
            autosens: AAPSAutosensResult(
                ratio: d(ad, "ratio", 1),
                ratioFromTdd: d(ad, "ratioFromTdd", 1),
                ratioFromCarbs: d(ad, "ratioFromCarbs", 1)
            ),
            meal: AAPSMealData(
                carbs: d(meal, "carbs"),
                mealCOB: d(meal, "mealCOB"),
                slopeFromMaxDeviation: d(meal, "slopeFromMaxDeviation"),
                slopeFromMinDeviation: d(meal, "slopeFromMinDeviation", 999),
                lastBolusTime: l(meal, "lastBolusTime"),
                lastCarbTime: l(meal, "lastCarbTime")
            ),
            microBolusAllowed: mba,
            flat: flat,
            dyn: dyn,
            onDynamic: onDynamic,
            logged: res
        )
    }

    // MARK: - Replay

    /// The tier table seen in the logs: default edges, multipliers read back from the
    /// "ISF tier: BG x m" lines, defaults elsewhere.
    static func tiers(seenIn records: [Record]) -> [AAPSIsfTiers.Tier] {
        var tiers = AAPSIsfTiers.defaults
        for r in records {
            for line in r.logged["consoleLog"] as? [String] ?? [] where line.hasPrefix("ISF tier: BG ") {
                let rest = line.dropFirst("ISF tier: BG ".count)
                let parts = rest.split(separator: " ")
                guard parts.count >= 2, let g = Double(parts[0]), parts[1].hasPrefix("x"),
                      let m = Double(parts[1].dropFirst()) else { continue }
                if let idx = tiers.firstIndex(where: { g >= $0.bgMin && g < $0.bgMax }) {
                    tiers[idx] = AAPSIsfTiers.Tier(bgMin: tiers[idx].bgMin, bgMax: tiers[idx].bgMax, isfMultiplier: m)
                }
            }
        }
        return tiers
    }

    static func run(_ r: Record, tiers: [AAPSIsfTiers.Tier], timeZone: TimeZone = .current) -> AAPSResult {
        AAPSDetermineBasalSMB.determineBasal(
            glucoseStatus: r.glucoseStatus,
            currenttemp: r.currentTemp,
            iobDataArray: r.iobArray,
            profile: r.profile,
            autosensData: r.autosens,
            mealData: r.meal,
            microBolusAllowed: r.microBolusAllowed,
            currentTime: r.ts,
            flatBGsDetected: r.flat,
            dynIsfMode: r.dyn,
            isfTiersEnabled: true,
            isfTiers: tiers,
            autosensMin: 0.7,
            isfTiersOnDynamic: r.onDynamic,
            timeZone: timeZone
        )
    }

    /// The decision branch, read from the reason text the same way for AAPS and the port.
    static func branch(_ reason: String) -> String {
        let markers = [
            "CGM is calibrating", "BG data is too old", "CGM data is unchanged",
            "minGuardBG", "Canceling temp at", "naive_eventualBG < 40",
            "is a lot less than needed", "~< req", "zero temp. ", "Eventual BG", "in range: no temp required",
            "> max_iob", "Microbolusing", "Waiting", "low temp of", "> 2 * insulinReq", "no temp, setting",
            ">~ req", "U/hr. ", "no temp required", "setting current basal", "Setting neutral temp", "maxDelta"
        ]
        let conclusion = reason.components(separatedBy: "; ").dropFirst().joined(separator: "; ")
        return markers.filter { conclusion.contains($0) }.joined(separator: "|")
    }

    private static func fmt(_ v: Double?) -> String { v.map { "\($0)" } ?? "nil" }
    private static func fmt(_ v: Int?) -> String { v.map { "\($0)" } ?? "nil" }

    private static func number(_ any: Any?) -> Double? { (any as? NSNumber)?.doubleValue }

    private static func ints(_ any: Any?) -> [Int]? { (any as? [NSNumber])?.map(\.intValue) }

    /// "minGuardBG 62" style values in the logged reason.
    static func reasonValue(_ reason: String, _ key: String) -> Double? {
        guard let range = reason.range(of: key + " ") else { return nil }
        let tail = reason[range.upperBound...]
        let token = tail.prefix { "-0123456789.".contains($0) }
        return Double(token)
    }

    static func compare(records: [Record], timeZone: TimeZone = .current) -> Report {
        let tiers = tiers(seenIn: records)
        var report = Report()
        for r in records {
            let out = run(r, tiers: tiers, timeZone: timeZone)
            let log = r.logged
            report.checked += 1
            func miss(_ field: String, _ e: String, _ a: String) {
                report.mismatches.append(Mismatch(ts: r.ts, field: field, expected: e, actual: a))
            }

            let eBG = number(log["eventualBG"])
            if eBG == out.eventualBG { report.eventualExact += 1 } else { miss("eventualBG", fmt(eBG), fmt(out.eventualBG)) }
            if let e = eBG, let a = out.eventualBG, abs(e - a) <= 1 { report.eventualWithin1 += 1 }

            let iReq = number(log["insulinReq"])
            if abs((iReq ?? 0) - (out.insulinReq ?? 0)) < 0.0005, (iReq == nil) == (out.insulinReq == nil) {
                report.insulinReqEqual += 1
            } else { miss("insulinReq", fmt(iReq), fmt(out.insulinReq)) }

            let units = number(log["units"])
            let unitsOK = (units == nil && out.units == nil) ||
                (units != nil && out.units != nil && abs(units! - out.units!) < 1E-9)
            if unitsOK { report.unitsEqual += 1 } else { miss("units", fmt(units), fmt(out.units)) }

            let rate = number(log["rate"])
            let duration = (log["duration"] as? NSNumber)?.intValue
            let rateOK = (rate == nil && out.rate == nil) || (rate != nil && out.rate != nil && abs(rate! - out.rate!) < 1E-9)
            let tempOK = rateOK && duration == out.duration
            if tempOK { report.tempEqual += 1 }
            else { miss("temp", "\(fmt(rate))/\(fmt(duration))", "\(fmt(out.rate))/\(fmt(out.duration))") }
            if unitsOK, tempOK { report.doseIdentical += 1 }

            let carbsReq = (log["carbsReq"] as? NSNumber)?.intValue
            if carbsReq == out.carbsReq { report.carbsReqEqual += 1 } else { miss("carbsReq", fmt(carbsReq), fmt(out.carbsReq)) }

            let reason = log["reason"] as? String ?? ""
            if let g = reasonValue(reason, "minGuardBG"), g == out.trace.minGuardBG { report.minGuardEqual += 1 }
            else { miss("minGuardBG", fmt(reasonValue(reason, "minGuardBG")), fmt(out.trace.minGuardBG)) }
            if let g = reasonValue(reason, "minPredBG"), g == out.trace.minPredBG { report.minPredEqual += 1 }
            else { miss("minPredBG", fmt(reasonValue(reason, "minPredBG")), fmt(out.trace.minPredBG)) }
            let loggedFS = reasonValue(reason, "Dosing sensitivity:")
            if loggedFS == (r.dyn ? out.trace.futureSens : nil) { report.dosingSensEqual += 1 }
            else { miss("dosingSens", fmt(loggedFS), fmt(out.trace.futureSens)) }

            if branch(reason) == branch(out.reason) { report.branchEqual += 1 }
            else { miss("branch", branch(reason), branch(out.reason)) }
            if reason == out.reason { report.reasonExact += 1 } else { miss("reason", reason, out.reason) }

            let preds = log["predBGs"] as? [String: Any] ?? [:]
            let predOK = ints(preds["IOB"]) == out.predIOB && ints(preds["ZT"]) == out.predZT
                && ints(preds["UAM"]) == out.predUAM && ints(preds["COB"]) == out.predCOB
            if predOK { report.predictionsEqual += 1 } else { miss("predBGs", "", "") }
        }
        return report
    }
}

// MARK: - Dynamic ISF (plugin level)

extension AAPSEquivalence {
    struct DynIsfReport {
        var lines = 0
        var tddEqual = 0
        var variableSensEqual = 0
        var paired = 0
        var autosensEqual = 0
        var profileEqual = 0
        var mismatches: [String] = []

        var summary: String {
            """
            dynIsfResult log lines \(lines): TDD blend equal \(tddEqual), variable ISF equal \(variableSensEqual)
            loop runs paired with their dynIsfResult line \(paired): autosens ratio equal \(autosensEqual), profile TDD and variable ISF equal \(profileEqual)
            """
        }
    }

    private static func peak(forDivisor divisor: Int) -> Double { divisor == 55 ? 75 : divisor == 65 ? 55 : 45 }

    private static func jsonObject(in line: Substring, key: String) -> [String: Any]? {
        guard let r = line.range(of: key + "={") else { return nil }
        let start = line.index(before: r.upperBound)
        var depth = 0
        var idx = start
        while idx < line.endIndex {
            let c = line[idx]
            if c == "{" { depth += 1 } else if c == "}" {
                depth -= 1
                if depth == 0 {
                    return (try? JSONSerialization.jsonObject(with: Data(line[start ... idx].utf8))) as? [String: Any]
                }
            }
            idx = line.index(after: idx)
        }
        return nil
    }

    private static func field(_ line: Substring, _ key: String) -> String? {
        guard let r = line.range(of: " " + key + "=") else { return nil }
        return String(line[r.upperBound...].prefix { $0 != " " })
    }

    /// Recomputes every logged `calculateRawDynIsf` result from its logged parts, and checks the
    /// autosens ratio and profile values of the loop run that follows it.
    static func compareDynamicIsf(logsDirectory: URL, adjustmentFactorPercent: Int = 100) -> DynIsfReport {
        var report = DynIsfReport()
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: logsDirectory, includingPropertiesForKeys: nil) else { return report }
        var seenRuns = Set<Int64>()
        for case let url as URL in walker {
            guard let text = try? String(contentsOf: url, encoding: .utf8) ?? String(contentsOf: url, encoding: .isoLatin1)
            else { continue }
            typealias Calc = (inputs: AAPSDynamicISF.TddInputs, tdd: Double, glucose: Double, divisor: Int, multiplier: Double)
            // Every calculateRawDynIsf line since the loop run started. The plugin's own call is one
            // of them; others come from ISF lookups that run alongside and can see a later 24 h window.
            var sinceInvoke: [Calc] = []
            for line in text.split(separator: "\n") {
                if line.contains("OpenAPSSMBPlugin.invoke():"), line.contains("invoke from") {
                    sinceInvoke = []
                } else if line.contains("calculateRawDynIsf():"), line.contains("dynIsfResult=") {
                    guard let mult = line.range(of: "multiplier=")
                        .flatMap({ Double(line[$0.upperBound...].prefix { $0 != " " }) }),
                        let tdd = field(line, "tdd").flatMap({ Double($0) }),
                        let vs = field(line, "variableSensitivity").flatMap({ Double($0) }),
                        let g = field(line, "glucoseStatus").flatMap({ Double($0) }),
                        let div = field(line, "insulinDivisor").flatMap({ Int($0) })
                    else { continue }
                    let inputs = AAPSDynamicISF.TddInputs(
                        tdd1D: field(line, "tdd1D").flatMap({ Double($0) }),
                        tdd7D: field(line, "tdd7D").flatMap({ Double($0) }),
                        tddLast24H: field(line, "tddLast24H").flatMap({ Double($0) }),
                        tddLast4H: field(line, "tddLast4H").flatMap({ Double($0) }),
                        tddLast8to4H: field(line, "tddLast8to4H").flatMap({ Double($0) }),
                        tddLast24HCarbs: 0,
                        tdd7DDataCarbs: field(line, "tdd7DDataCarbs").flatMap({ Double($0) }) ?? 0,
                        tdd7DAllDaysHaveCarbs: field(line, "tdd7DAllDaysHaveCarbs") == "true"
                    )
                    let r = AAPSDynamicISF.calculate(
                        inputs: inputs, glucose: g, adjustmentFactorPercent: adjustmentFactorPercent,
                        profileMultiplier: mult, insulinPeakMinutes: peak(forDivisor: div)
                    )
                    report.lines += 1
                    if r.tdd == tdd { report.tddEqual += 1 }
                    else { report.mismatches.append("tdd \(tdd) vs \(String(describing: r.tdd))") }
                    if r.variableSensitivity == vs { report.variableSensEqual += 1 }
                    else { report.mismatches.append("variableSensitivity \(vs) vs \(String(describing: r.variableSensitivity))") }
                    sinceInvoke.append((inputs, tdd, g, div, mult))
                } else if line.contains("Inserted APSResult APSResult("), !sinceInvoke.isEmpty {
                    guard let profile = jsonObject(in: line, key: "profileJson"),
                          let autosens = jsonObject(in: line, key: "autosensDataJson"),
                          let tddLogged = (profile["TDD"] as? NSNumber)?.doubleValue,
                          let tsRange = line.range(of: ", timestamp="),
                          let ts = Int64(line[tsRange.upperBound...].prefix { $0.isNumber }),
                          !seenRuns.contains(ts)
                    else { continue }
                    let candidates = sinceInvoke.filter { $0.tdd == tddLogged }
                    guard !candidates.isEmpty else { continue }
                    seenRuns.insert(ts)
                    report.paired += 1
                    let ratio = (autosens["ratio"] as? NSNumber)?.doubleValue ?? 1
                    let fromTdd = (autosens["ratioFromTdd"] as? NSNumber)?.doubleValue ?? 1
                    let fromCarbs = (autosens["ratioFromCarbs"] as? NSNumber)?.doubleValue ?? 1
                    let autosensOK = candidates.contains { c in
                        var inputs = c.inputs
                        // the 24 h carb total is not logged, so recover it from the logged carbs ratio
                        inputs.tddLast24HCarbs = ((fromCarbs - 1.0) / 0.6 + 1.0) * inputs.tdd7DDataCarbs
                        guard let a = AAPSDynamicISF.autosens(inputs: inputs, adjustSensitivity: true) else { return false }
                        return a.ratioFromTdd == fromTdd && abs(a.ratio - ratio) < 1E-12
                    }
                    if autosensOK { report.autosensEqual += 1 }
                    else { report.mismatches.append("autosens \(ratio)/\(fromTdd) at \(ts)") }
                    let vsLogged = (profile["variable_sens"] as? NSNumber)?.doubleValue
                    let divLogged = (profile["insulinDivisor"] as? NSNumber)?.intValue
                    let profileOK = candidates.contains { c in
                        let r = AAPSDynamicISF.calculate(
                            inputs: c.inputs, glucose: c.glucose, adjustmentFactorPercent: adjustmentFactorPercent,
                            profileMultiplier: c.multiplier, insulinPeakMinutes: peak(forDivisor: c.divisor)
                        )
                        return r.variableSensitivity == vsLogged && r.tdd == tddLogged && r.insulinDivisor == divLogged
                    }
                    if profileOK { report.profileEqual += 1 } else { report.mismatches.append("profile at \(ts)") }
                }
            }
        }
        return report
    }
}
