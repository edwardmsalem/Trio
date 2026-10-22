import Foundation

/// BG-range ISF tiers exactly as Eddie's AAPS fork applies them
/// (`plugins/aps/.../openAPSSMB/IsfTiers.kt`, release 42bb385ff4).
///
/// Used only by the AAPS dosing mode. Double arithmetic on purpose: AAPS computes in Double,
/// and the equivalence test compares against AAPS's logged numbers.
enum AAPSIsfTiers {
    struct Tier: Equatable {
        let bgMin: Double
        let bgMax: Double
        let isfMultiplier: Double
    }

    /// Never tier carbs below this: in-range meals dose normally.
    static let carbTierBGFloor = 140.0
    /// However aggressive the ISF tier, carb ratio never strengthens beyond this.
    static let carbTierMaxAggression = 1.3
    /// Nothing may be configured stronger than double strength, or weaker than half.
    static let minMultiplier = 0.5
    static let maxMultiplier = 2.0

    /// The Trio defaults, same as AAPS `IsfTiers.DEFAULT`.
    static let defaults: [Tier] = [
        Tier(bgMin: 0, bgMax: 70, isfMultiplier: 1.2),
        Tier(bgMin: 70, bgMax: 140, isfMultiplier: 1.0),
        Tier(bgMin: 140, bgMax: 200, isfMultiplier: 0.9),
        Tier(bgMin: 200, bgMax: 250, isfMultiplier: 0.8),
        Tier(bgMin: 250, bgMax: 400, isfMultiplier: 0.7)
    ]

    /// AAPS `IsfTiers.fromPercents`: fixed boundaries, multipliers clamped to 0.5...2.0,
    /// and the under-70 band never below 1.0.
    static func fromPercents(underSeventy: Int, inRange: Int, raised: Int, high: Int, veryHigh: Int) -> [Tier] {
        func m(_ percent: Int) -> Double { min(max(Double(percent) / 100.0, minMultiplier), maxMultiplier) }
        return [
            Tier(bgMin: 0, bgMax: 70, isfMultiplier: max(m(underSeventy), 1.0)),
            Tier(bgMin: 70, bgMax: 140, isfMultiplier: m(inRange)),
            Tier(bgMin: 140, bgMax: 200, isfMultiplier: m(raised)),
            Tier(bgMin: 200, bgMax: 250, isfMultiplier: m(high)),
            Tier(bgMin: 250, bgMax: 400, isfMultiplier: m(veryHigh))
        ]
    }

    /// Maps Trio's editable tier list onto AAPS's five fixed bands.
    ///
    /// AAPS keeps the band edges fixed at 70, 140, 200 and 250 and only lets the strength move.
    /// Trio lets the edges move too. For each AAPS band the multiplier is taken from the Trio tier
    /// that covers the band's lower edge, so a Trio list with the default edges maps one to one.
    /// The result then goes through `fromPercents` so AAPS's clamps (0.5 to 2.0, and under 70
    /// never below 100%) always hold.
    static func fromTrio(_ trioTiers: [InsulinSensitivityTier]) -> [Tier] {
        func percent(at glucose: Double) -> Int {
            for tier in trioTiers {
                let lo = Double(truncating: tier.bgMin as NSNumber)
                let hi = Double(truncating: tier.bgMax as NSNumber)
                if glucose >= lo, glucose < hi {
                    let m = Double(truncating: tier.isfMultiplier as NSNumber)
                    return Int((m * 100).rounded())
                }
            }
            return 100
        }
        return fromPercents(
            underSeventy: percent(at: 0),
            inRange: percent(at: 70),
            raised: percent(at: 140),
            high: percent(at: 200),
            veryHigh: percent(at: 250)
        )
    }

    /// The multiplier in force at this glucose, or 1.0 if no tier covers it.
    static func multiplierFor(_ glucose: Double, _ tiers: [Tier] = defaults) -> Double {
        for t in tiers where glucose >= t.bgMin && glucose < t.bgMax {
            return t.isfMultiplier
        }
        return 1.0
    }

    /// AAPS `trioOrderedSensitivity`: tier the profile ISF, then recover the dynamic ratio
    /// from AAPS's variable sensitivity and clamp it to the autosens limits.
    static func trioOrderedSensitivity(
        profileSens: Double,
        dynamicSens: Double,
        glucose: Double,
        tiers: [Tier],
        autosensMin: Double,
        autosensMax: Double
    ) -> Double {
        if dynamicSens <= 0.0 || profileSens <= 0.0 { return dynamicSens }
        let tiered = profileSens * multiplierFor(glucose, tiers)
        let ratio = min(max(tiered / dynamicSens, autosensMin), autosensMax)
        return tiered / ratio
    }

    static func applyToSensitivity(_ sens: Double, _ glucose: Double, _ tiers: [Tier]) -> Double {
        sens * multiplierFor(glucose, tiers)
    }

    /// AAPS `applyToCarbRatio`: damped, only aggressive tiers, only at BG 140 and up, capped at 1.3x.
    static func applyToCarbRatio(_ carbRatio: Double, _ glucose: Double, _ tiers: [Tier]) -> Double {
        if glucose < carbTierBGFloor { return carbRatio }
        let multiplier = multiplierFor(glucose, tiers)
        if multiplier <= 0.0 || multiplier >= 1.0 { return carbRatio }
        let isfAggression = 1.0 / multiplier
        let damped = (isfAggression - 1.0) / 2.0 + 1.0
        let capped = damped > carbTierMaxAggression ? carbTierMaxAggression : damped
        return carbRatio / capped
    }
}
