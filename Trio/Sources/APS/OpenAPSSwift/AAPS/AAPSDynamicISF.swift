import Foundation

/// AAPS Dynamic ISF as `OpenAPSSMBPlugin` computes it before calling DetermineBasalSMB
/// (Eddie's fork, release 42bb385ff4: `calculateRawDynIsf` and the TDD-based autosens in `invoke`).
///
/// - TDD blend: `((1.4 * last4h + 0.6 * last8to4h) * 3 * 0.33 + 7-day * 0.34 + yesterday * 0.33)
///   * adjustmentFactor% / 100 * profilePercentage`.
/// - Trio addition: the recent-hours term (`(1.4 * last4h + 0.6 * last8to4h) * 3`, already scaled
///   to a day) is capped at 1.2 x the 7-day TDD (yesterday's when there is no 7-day figure), so a
///   few big meal boluses cannot pull the blend far above a normal day. The cap only ever lowers it.
/// - Variable ISF: `1800 / (TDD * ln(BG / insulinDivisor + 1))`, rounded to 0.1.
/// - Autosens ratio: `last24h / 7-day`, then divided by a carbs ratio
///   `(last24hCarbs / 7-dayCarbs - 1) * 0.6 + 1` when every one of the 7 days has carbs.
///   No autosens min/max clamp is applied here, which is how AAPS does it.
enum AAPSDynamicISF {
    /// The TDD figures AAPS reads from its TddCalculator.
    struct TddInputs: Equatable, Codable {
        /// Yesterday, midnight to midnight (AAPS `calculate(1)`).
        var tdd1D: Double?
        /// Average of the last 7 complete days (AAPS `calculate(7)`, no missing days allowed).
        var tdd7D: Double?
        /// Rolling last 24 hours.
        var tddLast24H: Double?
        /// Rolling last 4 hours.
        var tddLast4H: Double?
        /// The 4 hours before that (8 to 4 hours ago).
        var tddLast8to4H: Double?
        /// Carbs entered in the last 24 hours.
        var tddLast24HCarbs: Double = 0
        /// Average daily carbs over the same 7 days as `tdd7D`.
        var tdd7DDataCarbs: Double = 0
        /// True when every one of those 7 days had some carbs.
        var tdd7DAllDaysHaveCarbs: Bool = false

        var partsCalculated: Bool {
            tdd1D != nil && tdd7D != nil && tddLast24H != nil && tddLast4H != nil && tddLast8to4H != nil
        }
    }

    struct Result: Equatable {
        var tdd: Double?
        var variableSensitivity: Double?
        var insulinDivisor: Int
        var partsCalculated: Bool
        /// True when the recent-hours term was lowered by `recentTddCapRatio`.
        var recentTddCapped: Bool = false
    }

    /// The recent-hours term may be at most this multiple of the 7-day (else yesterday's) TDD.
    static let recentTddCapRatio = 1.2

    /// The recent-hours term (scaled to 24 h) after the cap, and whether the cap lowered it.
    /// Never raises the term. Without a 7-day or yesterday figure there is nothing to cap against.
    static func cappedRecentTdd(_ recent: Double, tdd7D: Double?, tdd1D: Double?) -> (value: Double, capped: Bool) {
        guard let reference = tdd7D ?? tdd1D, reference > 0 else { return (recent, false) }
        let cap = recentTddCapRatio * reference
        return recent > cap ? (cap, true) : (recent, false)
    }

    /// AAPS insulin divisor from the insulin's peak time in minutes.
    static func insulinDivisor(peakMinutes: Double) -> Int {
        if peakMinutes > 65 { return 55 } // rapid acting, peak 75
        if peakMinutes > 50 { return 65 } // ultra rapid, peak 55
        return 75 // Lyumjev, peak 45
    }

    /// AAPS `Round.roundTo(x, 0.1)`.
    static func roundToTenth(_ x: Double) -> Double {
        if x == 0 { return 0 }
        return AAPSFormat.javaRound(x / 0.1) / 10.0
    }

    static func calculate(
        inputs: TddInputs,
        glucose: Double?,
        adjustmentFactorPercent: Int,
        profileMultiplier: Double,
        insulinPeakMinutes: Double
    ) -> Result {
        var result = Result(
            tdd: nil,
            variableSensitivity: nil,
            insulinDivisor: insulinDivisor(peakMinutes: insulinPeakMinutes),
            partsCalculated: inputs.partsCalculated
        )
        guard inputs.partsCalculated, let glucose,
              let tdd1D = inputs.tdd1D, let tdd7D = inputs.tdd7D,
              let last4 = inputs.tddLast4H, let last8to4 = inputs.tddLast8to4H
        else { return result }
        let recent = cappedRecentTdd(((1.4 * last4) + (0.6 * last8to4)) * 3, tdd7D: tdd7D, tdd1D: tdd1D)
        let tddWeightedFromLast8H = recent.value
        result.recentTddCapped = recent.capped
        let tdd = ((tddWeightedFromLast8H * 0.33) + (tdd7D * 0.34) + (tdd1D * 0.33)) * Double(adjustmentFactorPercent) / 100.0 *
            profileMultiplier
        result.tdd = tdd
        result.variableSensitivity = roundToTenth(1800 / (tdd * log((glucose / Double(result.insulinDivisor)) + 1)))
        return result
    }

    /// The autosens result AAPS uses when Dynamic ISF runs.
    static func autosens(inputs: TddInputs, adjustSensitivity: Bool) -> AAPSAutosensResult? {
        guard inputs.partsCalculated, let last24 = inputs.tddLast24H, let tdd7D = inputs.tdd7D else { return nil }
        let tddRatio = adjustSensitivity ? last24 / tdd7D : 1.0
        let carbsRatio: Double
        if adjustSensitivity, inputs.tddLast24HCarbs != 0.0, inputs.tdd7DDataCarbs != 0.0, inputs.tdd7DAllDaysHaveCarbs {
            carbsRatio = ((inputs.tddLast24HCarbs / inputs.tdd7DDataCarbs - 1.0) * 0.6) + 1.0
        } else {
            carbsRatio = 1.0
        }
        return AAPSAutosensResult(ratio: tddRatio / carbsRatio, ratioFromTdd: tddRatio, ratioFromCarbs: carbsRatio)
    }
}
