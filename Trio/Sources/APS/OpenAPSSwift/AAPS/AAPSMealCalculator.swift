import Foundation

/// AAPS's carbs-on-board and deviation-slope calculation, ported from AAPS 3.4.2.6 as built in
/// Eddie's fork (release 42bb385ff4): `IobCobOref1Worker` (the Oref1 sensitivity plugin's
/// autosens-data pass), `AutosensDataObject` carb bookkeeping, `fromCarbs` and
/// `IobCobCalculatorPlugin.getMealDataWithWaitingForCalculationFinish`.
///
/// How it differs from Trio's oref meal code:
/// - COB runs as one chain over every 5-minute glucose bucket. Each bucket absorbs
///   max(deviation, min carb impact) x carb ratio / ISF from the active carb entries, oldest first,
///   and an entry is dropped once it is older than the absorption cut-off. Trio instead totals
///   absorption per meal since the meal and takes the largest remaining.
/// - The deviation slopes look back one hour over the 11 previous buckets. Trio looks back 45 minutes.
/// - Deviations use AAPS IOB against the scheduled basal and the ISF AAPS uses for carbs
///   (`isfForCarbs`), not Trio's IOB and profile ISF.
enum AAPSMealCalculator {
    struct Settings: Equatable {
        /// AAPS `openaps_smb_min_5m_carbimpact` (default 8).
        var min5mCarbImpact: Double = 8
        /// AAPS `absorption_cutoff`, hours (default 6).
        var absorptionCutoffHours: Double = 6
    }

    struct CarbInPast: Equatable {
        var time: Int64
        var carbs: Double
        var remaining: Double
    }

    struct Point: Equatable {
        var time: Int64
        var cob = 0.0
        var avgDeviation = 0.0
        var deviation = 0.0
        var slopeFromMaxDeviation = 0.0
        var slopeFromMinDeviation = 999.0
        var usedMinCarbsImpact = 0.0
        var activeCarbs: [CarbInPast] = []
    }

    /// `AutosensDataStore.roundUpTime`: up to the whole minute.
    static func roundUpTime(_ time: Int64) -> Int64 {
        time % 60000 == 0 ? time : (time / 60000 + 1) * 60000
    }

    /// The autosens-data table for the buckets (newest first), oldest point first. Only points
    /// before `now` are kept, as AAPS stores them.
    static func autosensTable(
        history: AAPSHistory,
        buckets: [AAPSGlucoseStatusCalculator.Bucket],
        now: Int64,
        curve: AAPSIob.Curve,
        isfForCarbs: (Int64) -> Double,
        carbRatio: (Int64) -> Double,
        settings: Settings = Settings(),
        calendar: Calendar = .current
    ) -> [Point] {
        guard buckets.count >= 3 else { return [] }
        var table: [Point] = []
        var index: [Int64: Int] = [:]
        var previous: Point?
        let cutoff = Int64(settings.absorptionCutoffHours * 60 * 60 * 1000)

        for i in stride(from: buckets.count - 4, through: 0, by: -1) {
            let bgTime = roundUpTime(buckets[i].time)
            if bgTime > roundUpTime(now) { continue }
            if let existing = index[bgTime] {
                previous = table[existing]
                continue
            }
            var point = Point(time: bgTime)
            point.activeCarbs = previous?.activeCarbs ?? []

            let bg = buckets[i].value
            guard bg >= 39, buckets[i + 3].value >= 39 else { continue }
            let delta = bg - buckets[i + 1].value
            let avgDelta = (bg - buckets[i + 3].value) / 3
            let sens = isfForCarbs(bgTime)
            let iob = AAPSIob.total(
                at: bgTime, now: bgTime, ratio: 1, curve: curve, history: history, includeZeroTemp: false, calendar: calendar
            )
            let bgi = -iob.activity * sens * 5
            let deviation = delta - bgi
            let avgDeviation = AAPSFormat.javaRound((avgDelta - bgi) * 1000) / 1000.0
            var slopeFromMaxDeviation = 0.0
            var slopeFromMinDeviation = 999.0

            // we need 1 h of data to calculate minDeviationSlope
            if i < buckets.count - 16 {
                var maxDeviation = 0.0
                var minDeviation = 999.0
                let hourAgo = bgTime + 10 * 1000 - 60 * 60 * 1000
                if let previousBucket = buckets.first(where: { $0.time <= hourAgo }),
                   let initialIndex = index[roundUpTime(previousBucket.time)]
                {
                    for past in 1 ..< 12 {
                        guard initialIndex + past < table.count else { break }
                        let ad = table[initialIndex + past]
                        let deviationSlope = (ad.avgDeviation - avgDeviation) / Double(ad.time - bgTime) * 1000 * 60 * 5
                        if ad.avgDeviation > maxDeviation {
                            slopeFromMaxDeviation = min(0, deviationSlope)
                            maxDeviation = ad.avgDeviation
                        }
                        if ad.avgDeviation < minDeviation {
                            slopeFromMinDeviation = max(0, deviationSlope)
                            minDeviation = ad.avgDeviation
                        }
                    }
                }
            }

            // carbs in (bgTime - 5 min, bgTime]
            var carbsFromBolus = 0.0
            for c in history.carbs where c.time >= bgTime - 5 * 60 * 1000 + 1 && c.time <= bgTime {
                carbsFromBolus += c.amount
                if c.amount > 0 { point.activeCarbs.append(CarbInPast(time: c.time, carbs: c.amount, remaining: c.amount)) }
            }

            if let previous, previous.cob > 0 {
                let ci = max(deviation, settings.min5mCarbImpact)
                var absorbed = ci * carbRatio(bgTime) / sens
                point.cob = max(previous.cob - absorbed, 0)
                // deductAbsorbedCarbs: oldest entries first
                var k = 0
                while k < point.activeCarbs.count, absorbed > 0 {
                    if point.activeCarbs[k].remaining > 0 {
                        let sub = min(absorbed, point.activeCarbs[k].remaining)
                        point.activeCarbs[k].remaining -= sub
                        absorbed -= sub
                    }
                    k += 1
                }
                point.usedMinCarbsImpact = settings.min5mCarbImpact
            }
            // removeOldCarbs
            point.activeCarbs.removeAll { c in
                guard c.time + cutoff < bgTime else { return false }
                if c.remaining > 0 { point.cob -= c.remaining }
                return true
            }
            point.cob = max(point.cob + carbsFromBolus, 0)
            point.deviation = deviation
            point.avgDeviation = avgDeviation
            point.slopeFromMaxDeviation = slopeFromMaxDeviation
            point.slopeFromMinDeviation = slopeFromMinDeviation

            previous = point
            if bgTime < now {
                index[bgTime] = table.count
                table.append(point)
            }
        }
        return table
    }

    /// `getMealDataWithWaitingForCalculationFinish`: carbs and last carb time over the absorption
    /// cut-off, and COB and slopes from the newest autosens point (when it is under 11 minutes old).
    static func mealData(history: AAPSHistory, table: [Point], now: Int64, settings: Settings = Settings()) -> AAPSMealData {
        var result = AAPSMealData()
        let absorptionTimeAgo = now - Int64(settings.absorptionCutoffHours * 60 * 60 * 1000)
        for c in history.carbs where c.time >= absorptionTimeAgo + 1 && c.time <= now && c.amount != 0 {
            result.carbs += c.amount
            if c.time > result.lastCarbTime { result.lastCarbTime = c.time }
        }
        if let last = table.last, last.time >= now - 11 * 60 * 1000 {
            result.mealCOB = last.cob
            result.slopeFromMinDeviation = last.slopeFromMinDeviation
            result.slopeFromMaxDeviation = last.slopeFromMaxDeviation
        }
        result.lastBolusTime = history.boluses.last.map(\.time) ?? 0
        return result
    }
}
