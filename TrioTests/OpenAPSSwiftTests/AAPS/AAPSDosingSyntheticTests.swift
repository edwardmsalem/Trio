import Foundation
import Testing
@testable import Trio

/// Made-up numbers only. Covers the pieces of the AAPS dosing mode one at a time.
@Suite("AAPS dosing synthetic") struct AAPSDosingSyntheticTests {
    // MARK: - Fixtures

    static let now: Int64 = 1_800_000_000_000

    static func profile(
        sens: Double = 50,
        maxBasal: Double = 4,
        maxDailyBasal: Double = 1,
        smbMinutes: Int = 30,
        uamMinutes: Int = 30,
        smbAlways: Bool = true,
        variableSens: Double = 0,
        tdd: Double = 0
    ) -> AAPSOapsProfile {
        AAPSOapsProfile(
            max_iob: 10, max_daily_basal: maxDailyBasal, max_basal: maxBasal, min_bg: 100, max_bg: 100, target_bg: 100,
            carb_ratio: 10, sens: sens, max_daily_safety_multiplier: 3, current_basal_safety_multiplier: 4,
            high_temptarget_raises_sensitivity: false, low_temptarget_lowers_sensitivity: false,
            sensitivity_raises_target: false, resistance_lowers_target: false, adv_target_adjustments: false,
            exercise_mode: false, half_basal_exercise_target: 160, skip_neutral_temps: false, remainingCarbsCap: 90,
            enableUAM: true, SMBInterval: 3, enableSMB_with_COB: false, enableSMB_with_temptarget: false,
            allowSMB_with_high_temptarget: false, enableSMB_always: smbAlways, enableSMB_after_carbs: false,
            maxSMBBasalMinutes: smbMinutes, maxUAMSMBBasalMinutes: uamMinutes, bolus_increment: 0.05,
            carbsReqThreshold: 1, current_basal: 1.0, temptargetSet: false, autosens_max: 1.2, lgsThreshold: nil,
            variable_sens: variableSens, insulinDivisor: 55, TDD: tdd
        )
    }

    static func iob(_ iob: Double = 0) -> [AAPSIobTotal] {
        (0 ..< 48).map { i in
            AAPSIobTotal(time: now + Int64(i) * 300_000, iob: iob, activity: 0, lastBolusTime: 0, iobWithZeroTemp: .init())
        }
    }

    static func run(
        bg: Double,
        delta: Double = 0,
        profile: AAPSOapsProfile = profile(),
        iobValue: Double = 0,
        dyn: Bool = false,
        tiers: Bool = false,
        onDynamic: Bool = true
    ) -> AAPSResult {
        AAPSDetermineBasalSMB.determineBasal(
            glucoseStatus: AAPSGlucoseStatus(glucose: bg, delta: delta, shortAvgDelta: delta, longAvgDelta: delta, date: now),
            currenttemp: AAPSCurrentTemp(),
            iobDataArray: iob(iobValue),
            profile: profile,
            autosensData: AAPSAutosensResult(),
            mealData: AAPSMealData(),
            microBolusAllowed: true,
            currentTime: now,
            flatBGsDetected: false,
            dynIsfMode: dyn,
            isfTiersEnabled: tiers,
            isfTiers: AAPSIsfTiers.defaults,
            autosensMin: 0.7,
            isfTiersOnDynamic: onDynamic,
            timeZone: TimeZone(identifier: "UTC")!
        )
    }

    // MARK: - Java number behaviour

    @Test("Java rounding is half up and drops negative zero") func javaRounding() {
        #expect(AAPSFormat.javaRound(2.5) == 3)
        #expect(AAPSFormat.javaRound(-2.5) == -2)
        #expect(AAPSFormat.javaRound(-0.2).sign == .plus)
        #expect(AAPSFormat.round(1.005, 2) == 1.0) // 1.005 is 1.00499... in binary
        #expect(AAPSFormat.withoutZeros(0.125) == "0.12") // HALF_EVEN
        #expect(AAPSFormat.withoutZeros(2.0) == "2")
        #expect(AAPSFormat.convertBg(-0.4) == "-0")
        #expect(AAPSFormat.kt(71.0) == "71.0")
        #expect(AAPSFormat.kt(0.0001) == "1.0E-4")
    }

    // MARK: - Tiers

    @Test("tier lookup and AAPS clamps") func tierLookup() {
        #expect(AAPSIsfTiers.multiplierFor(139.9) == 1.0)
        #expect(AAPSIsfTiers.multiplierFor(140) == 0.9)
        #expect(AAPSIsfTiers.multiplierFor(260) == 0.7)
        #expect(AAPSIsfTiers.multiplierFor(450) == 1.0)
        let tiers = AAPSIsfTiers.fromPercents(underSeventy: 60, inRange: 100, raised: 30, high: 80, veryHigh: 250)
        #expect(tiers[0].isfMultiplier == 1.0) // under 70 never stronger than 100%
        #expect(tiers[2].isfMultiplier == 0.5) // floor
        #expect(tiers[4].isfMultiplier == 2.0) // ceiling
    }

    @Test("Trio tier list maps onto the AAPS bands") func trioTierMapping() {
        let trio = InsulinSensitivityTier.defaultTiers
        #expect(AAPSIsfTiers.fromTrio(trio) == AAPSIsfTiers.defaults)
        var risky = trio
        risky[0].isfMultiplier = 0.8
        #expect(AAPSIsfTiers.fromTrio(risky)[0].isfMultiplier == 1.0)
    }

    @Test("carb ratio tier is damped, floored at 140 and capped") func carbTier() {
        #expect(AAPSIsfTiers.applyToCarbRatio(10, 139, AAPSIsfTiers.defaults) == 10)
        // 0.8: aggression 1.25, damped 1.125
        #expect(abs(AAPSIsfTiers.applyToCarbRatio(9, 210, AAPSIsfTiers.defaults) - 8) < 1E-12)
        // 0.5 would be 1.5 damped, capped at 1.3
        let strong = [AAPSIsfTiers.Tier(bgMin: 140, bgMax: 400, isfMultiplier: 0.5)]
        #expect(abs(AAPSIsfTiers.applyToCarbRatio(13, 200, strong) - 10) < 1E-12)
        // gentle tier never weakens meals
        #expect(AAPSIsfTiers.applyToCarbRatio(10, 60, AAPSIsfTiers.defaults) == 10)
    }

    @Test("Trio-order tier cancels against dynamic ISF until the autosens limit") func trioOrder() {
        // unclamped: tiered 45 / dynamic 40 = 1.125, so the result is the dynamic figure
        let unclamped = AAPSIsfTiers.trioOrderedSensitivity(
            profileSens: 50, dynamicSens: 40, glucose: 150, tiers: AAPSIsfTiers.defaults, autosensMin: 0.7, autosensMax: 1.2
        )
        #expect(abs(unclamped - 40) < 1E-12)
        // clamped: tiered 45 / 30 = 1.5 -> 1.2, result 37.5
        let clamped = AAPSIsfTiers.trioOrderedSensitivity(
            profileSens: 50, dynamicSens: 30, glucose: 150, tiers: AAPSIsfTiers.defaults, autosensMin: 0.7, autosensMax: 1.2
        )
        #expect(abs(clamped - 37.5) < 1E-12)
    }

    @Test("tiers on top of dynamic scale the dynamic ISF and the carb ratio") func tiersInCore() {
        let p = Self.profile(variableSens: 40, tdd: 50)
        let r = Self.run(bg: 210, profile: p, dyn: true, tiers: true, onDynamic: true)
        #expect(r.trace.tierMultiplier == 0.8)
        #expect(abs(r.trace.sens - 32) < 1E-12)
        #expect(abs(r.trace.carbRatio - 10 / 1.125) < 1E-12)
        let off = Self.run(bg: 210, profile: p, dyn: true, tiers: false)
        #expect(off.trace.sens == 40)
        #expect(off.trace.carbRatio == 10)
    }

    // MARK: - Dosing sensitivity

    @Test("insulinReq uses the dosing sensitivity, not the ISF") func dosingSensitivity() {
        let p = Self.profile(variableSens: 40, tdd: 50)
        let r = Self.run(bg: 150, delta: 2, profile: p, dyn: true)
        let expected = AAPSFormat.round(1800 / (log(150.0 / 55 + 1) * 50), 1)
        #expect(r.trace.futureSens == expected)
        #expect(r.reason.hasPrefix("Dosing sensitivity: \(AAPSFormat.kt(expected)) using current BG;"))
        let want = AAPSFormat.round((min(r.trace.minPredBG, r.trace.eventualBG) - 100) / expected, 2)
        #expect(r.insulinReq == want)
        #expect(want != AAPSFormat.round((min(r.trace.minPredBG, r.trace.eventualBG) - 100) / 40, 2))
    }

    @Test("AAPS Dynamic ISF TDD blend and variable ISF") func dynamicIsfFormula() {
        let inputs = AAPSDynamicISF.TddInputs(
            tdd1D: 40, tdd7D: 45, tddLast24H: 42, tddLast4H: 6, tddLast8to4H: 5,
            tddLast24HCarbs: 150, tdd7DDataCarbs: 120, tdd7DAllDaysHaveCarbs: true
        )
        let r = AAPSDynamicISF.calculate(
            inputs: inputs, glucose: 120, adjustmentFactorPercent: 100, profileMultiplier: 1, insulinPeakMinutes: 75
        )
        let blend = ((1.4 * 6 + 0.6 * 5) * 3 * 0.33) + 45 * 0.34 + 40 * 0.33
        #expect(abs(r.tdd! - blend) < 1E-12)
        #expect(r.insulinDivisor == 55)
        #expect(r.variableSensitivity == AAPSDynamicISF.roundToTenth(1800 / (blend * log(120.0 / 55 + 1))))
        let a = AAPSDynamicISF.autosens(inputs: inputs, adjustSensitivity: true)!
        #expect(abs(a.ratioFromTdd - 42.0 / 45.0) < 1E-12)
        #expect(abs(a.ratioFromCarbs - ((150.0 / 120.0 - 1) * 0.6 + 1)) < 1E-12)
        var missing = inputs
        missing.tdd7D = nil
        #expect(AAPSDynamicISF.calculate(
            inputs: missing, glucose: 120, adjustmentFactorPercent: 100, profileMultiplier: 1, insulinPeakMinutes: 75
        ).variableSensitivity == nil)
        #expect(AAPSDynamicISF.insulinDivisor(peakMinutes: 55) == 65)
        #expect(AAPSDynamicISF.insulinDivisor(peakMinutes: 45) == 75)
    }

    // MARK: - SMB size, caps, low guard

    @Test("SMB is half the insulinReq, capped by max SMB basal minutes") func smbCap() {
        // BG 200 flat, no IOB, ISF 50, target 100: insulinReq 2.0
        let capped = Self.run(bg: 200, profile: Self.profile(smbMinutes: 30))
        #expect(capped.insulinReq == 2.0)
        #expect(capped.units == 0.5) // 30 min of a 1.0 U/h basal
        #expect(capped.trace.maxBolus == 0.5)
        let roomy = Self.run(bg: 200, profile: Self.profile(smbMinutes: 90))
        #expect(roomy.units == 1.0) // half of 2.0, the fixed AAPS delivery ratio
    }

    @Test("temp basal never exceeds 4x the current basal") func fourTimesBasalCap() {
        // SMB off so the 2.0 U insulinReq goes into a temp: 1 + 2 * 2 = 5 U/h, capped at 4
        let p = Self.profile(maxBasal: 10, maxDailyBasal: 2, smbAlways: false)
        let r = Self.run(bg: 200, profile: p)
        #expect(r.rate == 4.0)
        #expect(r.duration == 30)
        // the tighter of max basal and 3x max daily basal wins when lower
        let tight = Self.run(bg: 200, profile: Self.profile(maxBasal: 4, maxDailyBasal: 1, smbAlways: false))
        #expect(tight.rate == 3.0)
    }

    @Test("predicted low below the threshold sets a zero temp and stops SMB") func lowGuard() {
        // BG 90 falling 4 per 5 min: guard 68 under threshold 70 (min_bg 100 -> 100 - 0.5 * 60)
        let r = Self.run(bg: 90, delta: -4)
        #expect(r.trace.threshold == 70)
        #expect(r.trace.minGuardBG == 68)
        #expect(r.rate == 0)
        #expect(r.duration == 30)
        #expect(r.units == nil)
        #expect(r.reason.contains("minGuardBG 68 < 70"))
    }

    // MARK: - Settings

    @Test("AAPS dosing is on by default and decodes leniently") func settingsDefaults() throws {
        #expect(AAPSDosingSettings.default.enabled)
        #expect(AAPSDosingSettings.default.tierOrder == .onTopOfDynamic)
        let decoded = try JSONDecoder()
            .decode(AAPSDosingSettings.self, from: Data(#"{"enabled":false,"adjustmentFactorPercent":5000}"#.utf8))
        #expect(!decoded.enabled)
        #expect(decoded.adjustmentFactorPercent == 300)
        #expect(decoded.dynamicISF)
    }

    // MARK: - Stock-mode tiers

    static func vars(
        tiers: Bool,
        carb: Bool,
        list: [InsulinSensitivityTier] = InsulinSensitivityTier.defaultTiers
    ) -> TrioCustomOrefVariables {
        TrioCustomOrefVariables(
            average_total_data: 0, weightedAverage: 0, currentTDD: 0, past2hoursAverage: 0, date: Date(),
            overridePercentage: 100, useOverride: false, duration: 0, unlimited: true, overrideTarget: 0,
            smbIsOff: false, advancedSettings: false, isfAndCr: false, isf: false, cr: false,
            smbIsScheduledOff: false, start: 0, end: 0, smbMinutes: 30, uamMinutes: 30,
            isfTiersEnabled: tiers, isfTiers: list, carbTierEnabled: carb
        )
    }

    @Test("stock tiers: multiplier, carb divisor and the under-70 clamp") func stockTiers() {
        #expect(
            StockIsfTiers.adjustment(currentGlucose: 210, trioCustomOrefVariables: Self.vars(tiers: false, carb: true))
                .isfMultiplier == 1
        )
        let high = StockIsfTiers.adjustment(currentGlucose: 210, trioCustomOrefVariables: Self.vars(tiers: true, carb: true))
        #expect(high.isfMultiplier == 0.8)
        #expect(high.carbRatioDivisor == InsulinSensitivityTiers.dampedCarbAggression(forISFMultiplier: 0.8))
        let noCarb = StockIsfTiers.adjustment(currentGlucose: 210, trioCustomOrefVariables: Self.vars(tiers: true, carb: false))
        #expect(noCarb.carbRatioDivisor == 1)
        #expect(
            StockIsfTiers.adjustment(currentGlucose: 60, trioCustomOrefVariables: Self.vars(tiers: true, carb: true))
                .isfMultiplier == 1.2
        )
        var risky = InsulinSensitivityTier.defaultTiers
        risky[0].isfMultiplier = 0.7
        let clamped = StockIsfTiers.adjustment(
            currentGlucose: 60,
            trioCustomOrefVariables: Self.vars(tiers: true, carb: true, list: risky)
        )
        #expect(clamped.isfMultiplier == 1)
        #expect(clamped.carbRatioDivisor == 1)
    }
}
