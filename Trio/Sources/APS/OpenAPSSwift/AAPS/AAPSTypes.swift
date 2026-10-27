import Foundation

// Inputs and output of the AAPS dosing mode, shaped like the AAPS types they port
// (core/interfaces/.../aps/*.kt in Eddie's AAPS fork, release 42bb385ff4).
// Field names keep AAPS's spelling so the port reads line for line against the Kotlin.
// Defaults are AAPS's defaults, which matter because AAPS leaves default values out of
// the JSON it logs.

struct AAPSGlucoseStatus: Equatable {
    var glucose: Double
    var noise: Double = 0
    var delta: Double = 0
    var shortAvgDelta: Double = 0
    var longAvgDelta: Double = 0
    /// Epoch milliseconds.
    var date: Int64
}

struct AAPSCurrentTemp: Equatable {
    var duration: Int = 0
    var rate: Double = 0
    var minutesrunning: Int?
}

struct AAPSIobTotal: Equatable {
    struct ZeroTemp: Equatable {
        var iob: Double = 0
        var activity: Double = 0
    }

    /// Epoch milliseconds.
    var time: Int64 = 0
    var iob: Double = 0
    var activity: Double = 0
    /// Epoch milliseconds.
    var lastBolusTime: Int64 = 0
    var iobWithZeroTemp: ZeroTemp?
}

struct AAPSMealData: Equatable {
    var carbs: Double = 0
    var mealCOB: Double = 0
    var slopeFromMaxDeviation: Double = 0
    var slopeFromMinDeviation: Double = 999
    var lastBolusTime: Int64 = 0
    var lastCarbTime: Int64 = 0
}

struct AAPSAutosensResult: Equatable {
    var ratio: Double = 1
    var ratioFromTdd: Double = 1
    var ratioFromCarbs: Double = 1
}

/// AAPS `OapsProfile`. Only the fields DetermineBasalSMB reads.
struct AAPSOapsProfile: Equatable {
    var max_iob: Double
    var max_daily_basal: Double
    var max_basal: Double
    var min_bg: Double
    var max_bg: Double
    var target_bg: Double
    var carb_ratio: Double
    var sens: Double
    var max_daily_safety_multiplier: Double
    var current_basal_safety_multiplier: Double
    var high_temptarget_raises_sensitivity: Bool
    var low_temptarget_lowers_sensitivity: Bool
    var sensitivity_raises_target: Bool
    var resistance_lowers_target: Bool
    var adv_target_adjustments: Bool
    var exercise_mode: Bool
    var half_basal_exercise_target: Int
    var skip_neutral_temps: Bool
    var remainingCarbsCap: Int
    var enableUAM: Bool
    var SMBInterval: Int
    var enableSMB_with_COB: Bool
    var enableSMB_with_temptarget: Bool
    var allowSMB_with_high_temptarget: Bool
    var enableSMB_always: Bool
    var enableSMB_after_carbs: Bool
    var maxSMBBasalMinutes: Int
    var maxUAMSMBBasalMinutes: Int
    var bolus_increment: Double
    var carbsReqThreshold: Int
    var current_basal: Double
    var temptargetSet: Bool
    var autosens_max: Double
    var lgsThreshold: Int?
    var variable_sens: Double
    var insulinDivisor: Int
    var TDD: Double
    /// Trio's "Enable SMB With High Glucose". AAPS has no such option, so it defaults off and only
    /// matters with SMB Always off: SMBs are then also allowed once glucose reaches the target.
    var enableSMB_high_bg: Bool = false
    var enableSMB_high_bg_target: Double = 110
}

/// How the ISF tiers combine with Dynamic ISF in the AAPS dosing mode.
enum AAPSTierOrder: String, Codable, CaseIterable, Identifiable {
    /// The tier multiplies the dynamic ISF result. Eddie's AAPS setting.
    case onTopOfDynamic
    /// Trio's old order: tier the profile ISF, then let the dynamic formula divide it back out
    /// (clamped to the autosens limits).
    case trioOrder

    var id: String { rawValue }
}

/// Values DetermineBasalSMB worked out on the way, kept for the equivalence test and logging.
struct AAPSDetermineBasalTrace: Equatable {
    var sens: Double = 0
    var carbRatio: Double = 0
    var bgi: Double = 0
    var deviation: Int = 0
    var naiveEventualBG: Double = 0
    var eventualBG: Double = 0
    var minPredBG: Double = 0
    var minGuardBG: Double = 0
    var minIOBPredBG: Double = 0
    var futureSens: Double = 0
    var targetBG: Double = 0
    var minBG: Double = 0
    var maxBG: Double = 0
    var threshold: Double = 0
    var basal: Double = 0
    var expectedDelta: Double = 0
    var minDelta: Double = 0
    var enableSMB: Bool = false
    var tierMultiplier: Double = 1
    /// The minGuardBG the low-glucose guard used: `minGuardBG`, or higher when upcoming carbs count.
    var guardBG: Double = 0
    /// True when upcoming carbs lifted the guard over the threshold and so stopped a block.
    var guardReleasedByUpcomingCarbs: Bool = false
    var maxBolus: Double?
    var microBolus: Double?
}

/// AAPS `RT`, the determine-basal result.
struct AAPSResult: Equatable {
    var bg: Double?
    var tick: String?
    var eventualBG: Double?
    var targetBG: Double?
    var insulinReq: Double?
    var carbsReq: Int?
    var carbsReqWithin: Int?
    var units: Double?
    /// Epoch milliseconds.
    var deliverAt: Int64?
    var sensitivityRatio: Double?
    var reason: String = ""
    var duration: Int?
    var rate: Double?
    var predIOB: [Int]?
    var predZT: [Int]?
    var predCOB: [Int]?
    var predUAM: [Int]?
    var predACOB: [Int]?
    var COB: Double?
    var IOB: Double?
    var variable_sens: Double?
    var trace = AAPSDetermineBasalTrace()
}
