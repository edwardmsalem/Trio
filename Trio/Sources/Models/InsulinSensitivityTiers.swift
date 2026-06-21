import Foundation

struct InsulinSensitivityTiers: JSON, Equatable {
    var enabled: Bool
    var tiers: [InsulinSensitivityTier]
    /// When true, the carb ratio is also tightened at high BG, derived from each
    /// tier's ISF multiplier but DAMPED (half-strength, capped) and only above
    /// BG 140. Requires `enabled`. Default OFF. See `dampedCarbDivisor`.
    var carbTierEnabled: Bool

    init(enabled: Bool, tiers: [InsulinSensitivityTier], carbTierEnabled: Bool = false) {
        self.enabled = enabled
        self.tiers = tiers
        self.carbTierEnabled = carbTierEnabled
    }

    /// Lowest BG (mg/dL) below which the carb tier is never applied, as a hard
    /// safety floor (in-range meals must not be over-bolused).
    static let carbTierBGFloor: Decimal = 140
    /// Maximum carb-ratio aggressiveness multiplier (caps the most resistant band).
    static let carbTierMaxAggression: Decimal = 1.3

    /// Given a tier's ISF multiplier (e.g. 0.7 = 1.43x more correction insulin),
    /// returns the DAMPED carb-ratio aggressiveness used to divide the carb ratio.
    /// Formula mirrors iAPS's dynamic-CR half-damper: (isfAggr - 1)/2 + 1, capped.
    /// Returns 1.0 (no change) for non-aggressive tiers (multiplier >= 1).
    static func dampedCarbAggression(forISFMultiplier isfMultiplier: Decimal) -> Decimal {
        guard isfMultiplier > 0, isfMultiplier < 1 else { return 1 }
        let isfAggression = 1 / isfMultiplier // e.g. 0.7 -> ~1.43
        let damped = (isfAggression - 1) / 2 + 1 // e.g. ~1.21
        return min(damped, carbTierMaxAggression)
    }
}

extension InsulinSensitivityTiers {
    private enum CodingKeys: String, CodingKey {
        case enabled
        case tiers
        case carbTierEnabled
    }
}

extension InsulinSensitivityTiers: Decodable {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        var result = InsulinSensitivityTiers(
            enabled: false,
            tiers: InsulinSensitivityTier.defaultTiers,
            carbTierEnabled: false
        )

        if let enabled = try? container.decode(Bool.self, forKey: .enabled) {
            result.enabled = enabled
        }

        if let tiers = try? container.decode([InsulinSensitivityTier].self, forKey: .tiers) {
            result.tiers = tiers
        }

        if let carbTierEnabled = try? container.decode(Bool.self, forKey: .carbTierEnabled) {
            result.carbTierEnabled = carbTierEnabled
        }

        self = result
    }
}

struct InsulinSensitivityTier: JSON, Equatable, Identifiable {
    var id = UUID()
    /// Lower bound of BG range in mg/dL
    var bgMin: Decimal
    /// Upper bound of BG range in mg/dL
    var bgMax: Decimal
    /// Multiplier to apply to profile ISF (e.g. 0.8 = 80% of normal ISF = more aggressive)
    var isfMultiplier: Decimal

    static let defaultTiers: [InsulinSensitivityTier] = [
        InsulinSensitivityTier(bgMin: 0, bgMax: 70, isfMultiplier: 1.2),
        InsulinSensitivityTier(bgMin: 70, bgMax: 140, isfMultiplier: 1.0),
        InsulinSensitivityTier(bgMin: 140, bgMax: 200, isfMultiplier: 0.9),
        InsulinSensitivityTier(bgMin: 200, bgMax: 250, isfMultiplier: 0.8),
        InsulinSensitivityTier(bgMin: 250, bgMax: 400, isfMultiplier: 0.7)
    ]
}

extension InsulinSensitivityTier {
    private enum CodingKeys: String, CodingKey {
        case bgMin = "bg_min"
        case bgMax = "bg_max"
        case isfMultiplier = "isf_multiplier"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = UUID()
        bgMin = try container.decode(Decimal.self, forKey: .bgMin)
        bgMax = try container.decode(Decimal.self, forKey: .bgMax)
        isfMultiplier = try container.decode(Decimal.self, forKey: .isfMultiplier)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(bgMin, forKey: .bgMin)
        try container.encode(bgMax, forKey: .bgMax)
        try container.encode(isfMultiplier, forKey: .isfMultiplier)
    }
}
