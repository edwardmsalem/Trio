import Foundation
import Testing

@testable import Trio

@Suite("ISF Carb-Tier Tests") struct ISFCarbTierTests {
    private func approx(_ a: Decimal, _ b: Double, tol: Double = 0.01) -> Bool {
        abs(NSDecimalNumber(decimal: a).doubleValue - b) < tol
    }

    // MARK: - Damped carb aggression formula

    @Test("non-aggressive ISF multipliers do not move the carb ratio") func noChangeWhenNotAggressive() {
        #expect(InsulinSensitivityTiers.dampedCarbAggression(forISFMultiplier: 1.0) == 1)
        #expect(InsulinSensitivityTiers.dampedCarbAggression(forISFMultiplier: 1.2) == 1)
        #expect(InsulinSensitivityTiers.dampedCarbAggression(forISFMultiplier: 0) == 1)
    }

    @Test("damper halves the ISF aggressiveness (0.85 ISF -> ~1.088 CR)") func damper085() {
        let aggr = InsulinSensitivityTiers.dampedCarbAggression(forISFMultiplier: 0.85)
        // isfAggr = 1/0.85 = 1.176; damped = (1.176-1)/2+1 = 1.088
        #expect(approx(aggr, 1.088))
    }

    @Test("damper for 0.70 ISF -> ~1.214 CR") func damper070() {
        let aggr = InsulinSensitivityTiers.dampedCarbAggression(forISFMultiplier: 0.70)
        // isfAggr = 1.4286; damped = (1.4286-1)/2+1 = 1.2143
        #expect(approx(aggr, 1.2143))
    }

    @Test("aggressive 0.50 ISF is CAPPED at +30% (1.30), not 1.50") func cappedAt130() {
        let aggr = InsulinSensitivityTiers.dampedCarbAggression(forISFMultiplier: 0.50)
        // isfAggr = 2.0; damped = (2-1)/2+1 = 1.5 -> capped to 1.30
        #expect(aggr == InsulinSensitivityTiers.carbTierMaxAggression)
        #expect(approx(aggr, 1.30))
    }

    @Test("very aggressive 0.40 ISF also capped at 1.30") func extremeCapped() {
        let aggr = InsulinSensitivityTiers.dampedCarbAggression(forISFMultiplier: 0.40)
        #expect(approx(aggr, 1.30))
    }

    // MARK: - Effective carb ratio (divisor application)

    @Test("CR 10 at 0.70 band becomes ~8.24 g/U") func effectiveCR070() {
        let aggr = InsulinSensitivityTiers.dampedCarbAggression(forISFMultiplier: 0.70)
        let cr: Decimal = 10 / aggr
        #expect(approx(cr, 8.24))
    }

    @Test("CR 10 at capped 0.50 band becomes ~7.69 g/U") func effectiveCR050() {
        let aggr = InsulinSensitivityTiers.dampedCarbAggression(forISFMultiplier: 0.50)
        let cr: Decimal = 10 / aggr
        #expect(approx(cr, 7.69))
    }

    // MARK: - Safety constants

    @Test("BG floor is 140 and cap is 1.30") func safetyConstants() {
        #expect(InsulinSensitivityTiers.carbTierBGFloor == 140)
        #expect(InsulinSensitivityTiers.carbTierMaxAggression == Decimal(string: "1.3"))
    }

    // MARK: - Default off + codable round-trip

    @Test("carb tier defaults OFF") func defaultsOff() {
        let t = InsulinSensitivityTiers(enabled: true, tiers: InsulinSensitivityTier.defaultTiers)
        #expect(t.carbTierEnabled == false)
    }

    @Test("carbTierEnabled survives a JSON encode/decode round-trip") func codableRoundTrip() throws {
        let original = InsulinSensitivityTiers(
            enabled: true,
            tiers: InsulinSensitivityTier.defaultTiers,
            carbTierEnabled: true
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(InsulinSensitivityTiers.self, from: data)
        #expect(decoded.carbTierEnabled == true)
        #expect(decoded.enabled == true)
    }
}
