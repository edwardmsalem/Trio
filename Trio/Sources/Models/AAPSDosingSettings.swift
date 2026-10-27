import Foundation

/// Settings for the AAPS dosing mode: Trio's Swift engine running Eddie's AAPS fork's
/// DetermineBasalSMB (see `APS/OpenAPSSwift/AAPS/`).
///
/// On by default in this fork. Switched off, Trio's stock oref engine runs exactly as upstream
/// (plus the restored ISF tiers). Defaults match the AAPS settings the fork shipped with.
struct AAPSDosingSettings: JSON, Equatable {
    /// Run the AAPS calculation instead of stock Trio.
    var enabled: Bool = true
    /// AAPS "Dynamic Sensitivity". Off means AAPS's plain profile ISF with Trio's autosens ratio.
    var dynamicISF: Bool = true
    /// AAPS "Adjustment factor" for Dynamic ISF, in percent (AAPS default 100).
    var adjustmentFactorPercent: Int = 100
    /// AAPS "Adjust sensitivity": derive the autosens ratio from last-24 h vs 7-day TDD and carbs.
    var adjustSensitivityFromTDD: Bool = true
    /// How ISF tiers combine with Dynamic ISF. AAPS "ISF tiers on top of dynamic" is the default.
    var tierOrder: AAPSTierOrder = .onTopOfDynamic
    /// Daily insulin total, in units, that stands in for each missing day of Trio's 7-day TDD history,
    /// so Dynamic ISF runs from the first day instead of waiting a week. 0 turns it off. Defaults to
    /// the 78 U 7-day TDD Eddie's AAPS ran with before the move to Trio on 2026-10-22.
    var startingTDD: Int = 78
    /// Off by default. Let the low-glucose guard count carb entries already entered but dated up to 2 hours ahead
    /// (Trio's fat and protein equivalents). Only the guard sees them: they never raise eventual BG,
    /// insulinReq, the SMB size or the COB shown. They can only re-allow SMBs at BG 150+ and not falling, never lift the zero-temp suspend.
    var guardSeesUpcomingCarbs: Bool = false

    static let `default` = AAPSDosingSettings()

    static let adjustmentFactorRange = 1 ... 300
    static let startingTDDRange = 0 ... 300
}

extension AAPSDosingSettings {
    private enum CodingKeys: String, CodingKey {
        case enabled
        case dynamicISF
        case adjustmentFactorPercent
        case adjustSensitivityFromTDD
        case tierOrder
        case startingTDD
        case guardSeesUpcomingCarbs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        var result = AAPSDosingSettings()
        if let v = try? container.decode(Bool.self, forKey: .enabled) { result.enabled = v }
        if let v = try? container.decode(Bool.self, forKey: .dynamicISF) { result.dynamicISF = v }
        if let v = try? container.decode(Int.self, forKey: .adjustmentFactorPercent) {
            result.adjustmentFactorPercent = min(
                max(v, Self.adjustmentFactorRange.lowerBound),
                Self.adjustmentFactorRange.upperBound
            )
        }
        if let v = try? container.decode(Bool.self, forKey: .adjustSensitivityFromTDD) { result.adjustSensitivityFromTDD = v }
        if let v = try? container.decode(AAPSTierOrder.self, forKey: .tierOrder) { result.tierOrder = v }
        if let v = try? container.decode(Int.self, forKey: .startingTDD) {
            result.startingTDD = min(max(v, Self.startingTDDRange.lowerBound), Self.startingTDDRange.upperBound)
        }
        if let v = try? container.decode(Bool.self, forKey: .guardSeesUpcomingCarbs) { result.guardSeesUpcomingCarbs = v }
        self = result
    }
}

/// What the loop hands the engine when the AAPS mode is on: the settings and the TDD figures
/// Trio gathered for AAPS Dynamic ISF. Nil in `TrioCustomOrefVariables` means stock Trio.
struct AAPSDosingContext: Codable, Equatable {
    var settings: AAPSDosingSettings
    var tdd: AAPSDynamicISF.TddInputs
    /// Trio's pump history, carbs and glucose in AAPS's shape, added by the loop just before dosing.
    /// With it the AAPS mode computes IOB, COB and glucose status with the AAPS ports
    /// (`AAPSIob`, `AAPSMealCalculator`, `AAPSGlucoseStatusCalculator`). Nil keeps Trio's own.
    var history: AAPSHistory?
    /// Dynamic ISF of recent AAPS-mode runs, for the ISF AAPS uses for carbs.
    var carbIsfCache: AAPSCarbIsfCache?
}
