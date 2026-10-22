import Foundation

/// ISF tiers for the stock Trio engine, restored from the fork's pre-1.0 JS
/// (`trio-oref/lib/determine-basal/determine-basal.js`, lines 186 to 240 on feat/v083-everything).
///
/// - ISF: the first tier whose range holds the current BG and whose multiplier is not 1 scales
///   the (override-adjusted) profile ISF. That happens before Dynamic ISF and autosens, so with
///   the logarithmic formula the tier is divided back out unless the ratio hits an autosens limit,
///   exactly as the JS behaved.
/// - Safety clamp from AAPS: below 70 mg/dL a tier never makes ISF stronger (multiplier floored
///   at 100%), however the tier list was edited.
/// - Carb ratio: only when the carb tier is switched on, only at BG 140 and up, only for tiers
///   below 100%, damped to half the ISF effect and capped at 1.3x.
enum StockIsfTiers {
    struct Adjustment: Equatable {
        var isfMultiplier: Decimal = 1
        var carbRatioDivisor: Decimal = 1
        var reason: String = ""
    }

    static let underSeventyFloorBG: Decimal = 70

    static func adjustment(currentGlucose bg: Decimal, trioCustomOrefVariables vars: TrioCustomOrefVariables) -> Adjustment {
        var result = Adjustment()
        guard vars.isfTiersEnabled, !vars.isfTiers.isEmpty else { return result }

        if let tier = vars.isfTiers.first(where: { bg >= $0.bgMin && bg < $0.bgMax && $0.isfMultiplier != 1 }) {
            var multiplier = tier.isfMultiplier
            if bg < underSeventyFloorBG, multiplier < 1 { multiplier = 1 }
            if multiplier != 1 {
                result.isfMultiplier = multiplier
                result.reason += ", ISF tier: x\(multiplier)"
            }
        }

        if vars.carbTierEnabled, bg >= InsulinSensitivityTiers.carbTierBGFloor,
           let tier = vars.isfTiers
           .first(where: { bg >= $0.bgMin && bg < $0.bgMax && $0.isfMultiplier > 0 && $0.isfMultiplier < 1 })
        {
            let divisor = InsulinSensitivityTiers.dampedCarbAggression(forISFMultiplier: tier.isfMultiplier)
            if divisor != 1 {
                result.carbRatioDivisor = divisor
                result.reason += ", Carb tier: CR / \(divisor.rounded(toPlaces: 2))"
            }
        }
        return result
    }
}
