import Foundation

/// AAPS's glucose bucketing and glucose status, ported from AAPS 3.4.2.6 as built in Eddie's fork
/// (release 42bb385ff4): `AutosensDataStoreObject.createBucketedData` (5-minute and recalculated
/// forms), `DeltaCalculator.calculateDeltas` and `GlucoseStatusCalculatorSMB` with no smoothing.
///
/// Differences from Trio's `getGlucoseStatus`:
/// - Readings are first put on an exact 5-minute grid (gaps over 8 minutes filled by straight-line
///   interpolation, readings under 2 minutes apart averaged), so every "minutes ago" is a multiple of 5.
/// - Delta is the average of the deltas 2.5 to 7.5 minutes back, or the short average when there is
///   none (Trio uses 0). Window edges are inclusive. "Now" is never averaged with a reading just before it.
/// - The status is rounded to 0.1 for glucose and 0.01 for the deltas.
enum AAPSGlucoseStatusCalculator {
    struct Bucket: Equatable {
        var time: Int64
        var value: Double
        var filledGap = false
    }

    private static let fiveMinutes: Int64 = 5 * 60 * 1000
    private static let irregularDataMs: Int64 = 30 * 1000

    /// `adjustToReferenceTime` with the reference set to the first time it is called.
    private static func adjust(_ t: Int64, reference: Int64) -> Int64 {
        var diff = abs(t - reference)
        diff %= fiveMinutes
        return diff > 150_000 ? t + abs(diff - fiveMinutes) : t - diff
    }

    /// `isAbout5minData`. Readings newest first.
    static func isAbout5minData(_ readings: [AAPSHistory.Glucose]) -> Bool {
        guard readings.count >= 3 else { return true }
        var totalDiff: Int64 = 0
        for i in 1 ..< readings.count {
            var diff = readings[i - 1].time - readings[i].time
            diff %= fiveMinutes
            if diff > 150_000 { diff -= fiveMinutes }
            totalDiff += diff
            if abs(diff) > irregularDataMs { return false }
        }
        let averageDiff = totalDiff / Int64(readings.count) / 1000
        return averageDiff < 1
    }

    /// `createBucketedData`. Readings newest first; returns buckets newest first, or nil when there
    /// are fewer than 3 readings. `reference` is AAPS's grid reference time. AAPS fixes it at the
    /// first bucketing after the app starts, so its grid follows the sensor's reading times. The
    /// newest reading stands in for it by default.
    static func bucketedData(_ readings: [AAPSHistory.Glucose], reference: Int64? = nil) -> [Bucket]? {
        guard readings.count >= 3 else { return nil }
        let ref = reference ?? readings[0].time
        if isAbout5minData(readings), let five = bucketed5min(readings, reference: ref) { return five }
        return bucketedRecalculated(readings, reference: ref)
    }

    private static func findNewer(_ readings: [AAPSHistory.Glucose], _ time: Int64) -> AAPSHistory.Glucose? {
        var lastFound = readings[0]
        if lastFound.time < time { return nil }
        for i in 1 ..< readings.count {
            if readings[i].time == time { return readings[i] }
            if readings[i].time > time { continue }
            lastFound = readings[i - 1]
            if readings[i].time < time { break }
        }
        return lastFound
    }

    private static func findOlder(_ readings: [AAPSHistory.Glucose], _ time: Int64) -> AAPSHistory.Glucose? {
        var lastFound = readings[readings.count - 1]
        if lastFound.time > time { return nil }
        for i in stride(from: readings.count - 2, through: 0, by: -1) {
            if readings[i].time == time { return readings[i] }
            if readings[i].time < time { continue }
            lastFound = readings[i + 1]
            if readings[i].time > time { break }
        }
        return lastFound
    }

    private static func bucketedRecalculated(_ readings: [AAPSHistory.Glucose], reference: Int64) -> [Bucket] {
        var result: [Bucket] = []
        var currentTime = readings[0].time
        let adjusted = adjust(currentTime, reference: reference)
        currentTime = adjusted > currentTime ? adjusted - fiveMinutes : adjusted
        while true {
            guard let newer = findNewer(readings, currentTime), let older = findOlder(readings, currentTime) else { break }
            if older.time == newer.time {
                result.append(Bucket(time: newer.time, value: newer.value))
            } else {
                let bgDelta = newer.value - older.value
                let toNew = newer.time - currentTime
                let toOld = currentTime - older.time
                let filled = min(toOld, toNew) > irregularDataMs
                let bg = newer.value - Double(toNew) / Double(newer.time - older.time) * bgDelta
                result.append(Bucket(time: currentTime, value: AAPSFormat.javaRound(bg), filledGap: filled))
            }
            currentTime -= fiveMinutes
        }
        return result
    }

    /// Nil means AAPS falls back to the recalculated form.
    private static func bucketed5min(_ readings: [AAPSHistory.Glucose], reference: Int64) -> [Bucket]? {
        var data: [Bucket] = [Bucket(time: readings[0].time, value: readings[0].value)]
        var j = 0
        for i in 1 ..< readings.count {
            let bgTime = readings[i].time
            var lastBgTime = readings[i - 1].time
            var elapsedMinutes = (bgTime - lastBgTime) / (60 * 1000)
            if abs(elapsedMinutes) > 8 {
                var lastBgValue = readings[i - 1].value
                elapsedMinutes = abs(elapsedMinutes)
                while elapsedMinutes > 5 {
                    let nextBgTime = lastBgTime - 5 * 60 * 1000
                    j += 1
                    let gapDelta = readings[i].value - lastBgValue
                    let nextBg = lastBgValue + 5.0 / Double(elapsedMinutes) * gapDelta
                    data.append(Bucket(time: nextBgTime, value: AAPSFormat.javaRound(nextBg), filledGap: true))
                    elapsedMinutes -= 5
                    lastBgValue = nextBg
                    lastBgTime = nextBgTime
                }
                j += 1
                data.append(Bucket(time: bgTime, value: readings[i].value))
            } else if abs(elapsedMinutes) > 2 {
                j += 1
                data.append(Bucket(time: bgTime, value: readings[i].value))
            } else {
                data[j].value = (data[j].value + readings[i].value) / 2
            }
        }
        // Normalise onto the 5-minute grid from the oldest bucket.
        data[data.count - 1].time = adjust(data[data.count - 1].time, reference: reference)
        for i in stride(from: data.count - 2, through: 0, by: -1) {
            let adjustedSec = (data[i].time - data[i + 1].time - fiveMinutes) / 1000
            if abs(adjustedSec) > 90 { return nil }
            data[i].time = data[i + 1].time + fiveMinutes
        }
        return data
    }

    /// `GlucoseStatusCalculatorSMB.getGlucoseStatusData(allowOldData = false)`. Nil when there is no
    /// reading or the newest bucket is more than 7 minutes old.
    static func glucoseStatus(buckets: [Bucket]?, now: Int64) -> AAPSGlucoseStatus? {
        guard let data = buckets, let first = data.first else { return nil }
        guard first.time >= now - 7 * 60 * 1000 else { return nil }
        if data.count == 1 {
            return AAPSGlucoseStatus(glucose: AAPSIob.roundTo(first.value, 0.1), date: first.time)
        }
        var lastDeltas: [Double] = []
        var shortDeltas: [Double] = []
        var longDeltas: [Double] = []
        for i in 1 ..< data.count where data[i].value > 39 {
            let minutesAgo = Double(first.time - data[i].time) / 60000.0
            let avgDel = (first.value - data[i].value) / minutesAgo * 5
            if minutesAgo >= 2.5, minutesAgo <= 7.5 { lastDeltas.append(avgDel) }
            if minutesAgo >= 2.5, minutesAgo <= 17.5 { shortDeltas.append(avgDel) }
            if minutesAgo >= 17.5, minutesAgo <= 42.5 {
                longDeltas.append(avgDel)
            } else if minutesAgo > 42.5 {
                break
            }
        }
        func average(_ a: [Double]) -> Double { a.isEmpty ? 0 : a.reduce(0, +) / Double(a.count) }
        let shortAvg = average(shortDeltas)
        let delta = lastDeltas.isEmpty ? shortAvg : average(lastDeltas)
        return AAPSGlucoseStatus(
            glucose: AAPSIob.roundTo(first.value, 0.1),
            noise: 0,
            delta: AAPSIob.roundTo(delta, 0.01),
            shortAvgDelta: AAPSIob.roundTo(shortAvg, 0.01),
            longAvgDelta: AAPSIob.roundTo(average(longDeltas), 0.01),
            date: first.time
        )
    }
}
