import Foundation

/// AAPS's insulin-on-board calculation, ported line by line from AAPS 3.4.2.6 as built in Eddie's
/// fork (release 42bb385ff4):
/// `InsulinOrefBasePlugin.iobCalcForTreatment`, `TemporaryBasalExtension.iobCalc`,
/// `IobCobCalculatorPlugin.calculateIobArrayForSMB` / `calculateFromTreatmentsAndTemps`, and
/// `IobTotal.round` / `combine`.
///
/// What makes it differ from Trio's oref IOB:
/// - Minutes since a dose are exact, not rounded to whole minutes.
/// - A temp basal is split into near-5-minute parts timed at their midpoints, not 0.05 U pulses.
/// - Temp basal insulin is counted against the scheduled basal times the autosens ratio AAPS
///   hands the dosing calculation, and only for temps that started within DIA of each tick.
/// - The zero-temp curve starts one minute after now and runs 240 minutes.
/// - Bolus and basal parts are rounded separately before they are added, as AAPS does.
enum AAPSIob {
    struct Curve: Equatable {
        var diaHours: Double
        var peakMinutes: Double
    }

    struct Contribution {
        var iob = 0.0
        var activity = 0.0
    }

    /// `InsulinOrefBasePlugin.iobCalcForTreatment`.
    static func treatment(amount: Double, time doseTime: Int64, at time: Int64, curve: Curve) -> Contribution {
        var result = Contribution()
        guard amount != 0 else { return result }
        let t = Double(time - doseTime) / 1000.0 / 60.0
        let td = curve.diaHours * 60
        let tp = curve.peakMinutes
        if t < td {
            let tau = tp * (1 - tp / td) / (1 - 2 * tp / td)
            let a = 2 * tau / td
            let s = 1 / (1 - a + (1 + a) * exp(-td / tau))
            result.activity = amount * (s / pow(tau, 2.0)) * t * (1 - t / td) * exp(-t / tau)
            result.iob = amount * (1 - s * (1 - a) * ((pow(t, 2.0) / (tau * td * (1 - a)) - t / tau - 1) * exp(-t / tau) + 1))
        }
        return result
    }

    /// Kotlin `roundToInt` / Java `Math.round`.
    private static func roundToInt(_ x: Double) -> Int64 { Int64(AAPSFormat.javaRound(x)) }

    /// `Round.roundTo(x, step)`: Math.round(x / step), times step as an exact decimal.
    static func roundTo(_ x: Double, _ step: Double) -> Double {
        if x == 0 { return 0 }
        return AAPSFormat.javaRound(x / step) / (1 / step).rounded()
    }

    /// `TB.iobCalc(time, profile, lastAutosensResult, ...)` with exercise mode off. `ratio` scales
    /// the scheduled basal the temp is counted against (1 for the COB pass, which uses the plain form).
    static func tempBasal(
        _ tb: AAPSHistory.TempBasal,
        at time: Int64,
        ratio: Double,
        curve: Curve,
        history: AAPSHistory,
        calendar: Calendar
    ) -> Contribution {
        var result = Contribution()
        let realDuration = roundToInt(Double(min(time, tb.end) - tb.time) / 60.0 / 1000)
        guard realDuration > 0 else { return result }
        let diaAgo = Double(time) - curve.diaHours * 60 * 60 * 1000
        let intervals = Int64(ceil(Double(realDuration) / 5.0))
        let spacing = Double(realDuration) / Double(intervals)
        for j in 0 ..< intervals {
            // middle of the interval
            let calcDate = Int64(Double(tb.time) + Double(j) * spacing * 60 * 1000 + 0.5 * spacing * 60 * 1000)
            let basalRate = history.basal(at: calcDate, calendar: calendar) * ratio
            let netBasalRate = tb.rate - basalRate
            if Double(calcDate) > diaAgo, calcDate <= time {
                let size = netBasalRate * spacing / 60.0
                let c = treatment(amount: size, time: calcDate, at: time, curve: curve)
                result.iob += c.iob
                result.activity += c.activity
            }
        }
        return result
    }

    struct Total {
        var iob = 0.0
        var activity = 0.0
        var lastBolusTime: Int64 = 0
        var zeroTempIob = 0.0
        var zeroTempActivity = 0.0
    }

    /// `calculateFromTreatmentsAndTemps(time, lastAutosensResult, ...)` for one tick. `now` caps the
    /// boluses and temps AAPS has stored. The expected zero temp starts a minute after `now`.
    static func total(
        at time: Int64,
        now: Int64,
        ratio: Double,
        curve: Curve,
        history: AAPSHistory,
        includeZeroTemp: Bool,
        calendar: Calendar
    ) -> Total {
        let range = Int64(curve.diaHours * 60 * 60 * 1000)
        var bolusIob = 0.0
        var bolusActivity = 0.0
        var last: Int64 = 0
        for b in history.boluses where b.time >= time - range && b.time < time && b.time <= now {
            let c = treatment(amount: b.amount, time: b.time, at: time, curve: curve)
            bolusIob += c.iob
            bolusActivity += c.activity
            if b.amount > 0, b.time > last { last = b.time }
        }
        bolusIob = roundTo(bolusIob, 0.001)
        bolusActivity = roundTo(bolusActivity, 0.0001)

        var basalIob = 0.0
        var basalActivity = 0.0
        for tb in history.temps where tb.time >= time - range && tb.time <= time && tb.time <= now {
            var capped = tb
            if capped.end > now { capped.duration = now - capped.time }
            let c = tempBasal(capped, at: time, ratio: ratio, curve: curve, history: history, calendar: calendar)
            basalIob += c.iob
            basalActivity += c.activity
        }
        basalIob = roundTo(basalIob, 0.001)
        basalActivity = roundTo(basalActivity, 0.0001)

        var result = Total(
            iob: roundTo(bolusIob + basalIob, 0.001),
            activity: roundTo(bolusActivity + basalActivity, 0.0001),
            lastBolusTime: last
        )
        guard includeZeroTemp else { return result }
        var ztIob = basalIob
        var ztActivity = basalActivity
        let zeroTemp = AAPSHistory.TempBasal(time: now + 60 * 1000, duration: 240 * 60 * 1000, rate: 0)
        if zeroTemp.time < time {
            let c = tempBasal(zeroTemp, at: time, ratio: ratio, curve: curve, history: history, calendar: calendar)
            ztIob += c.iob
            ztActivity += c.activity
        }
        result.zeroTempIob = roundTo(bolusIob + ztIob, 0.001)
        result.zeroTempActivity = roundTo(bolusActivity + ztActivity, 0.0001)
        return result
    }

    /// `calculateIobArrayForSMB`: 48 ticks, 5 minutes apart, from now.
    static func iobArray(
        history: AAPSHistory,
        now: Int64,
        autosensRatio: Double,
        curve: Curve,
        calendar: Calendar = .current
    ) -> [AAPSIobTotal] {
        (0 ..< 48).map { i in
            let time = now + Int64(i) * 5 * 60000
            let t = total(
                at: time, now: now, ratio: autosensRatio, curve: curve, history: history,
                includeZeroTemp: true, calendar: calendar
            )
            return AAPSIobTotal(
                time: time,
                iob: t.iob,
                activity: t.activity,
                lastBolusTime: t.lastBolusTime,
                iobWithZeroTemp: AAPSIobTotal.ZeroTemp(iob: t.zeroTempIob, activity: t.zeroTempActivity)
            )
        }
    }
}
