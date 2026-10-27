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

    // MARK: - SMB gate

    @Test("High glucose gate allows SMB only at or above its target when SMB Always is off") func highGlucoseGate() {
        var p = Self.profile(smbAlways: false)
        p.enableSMB_high_bg = true
        p.enableSMB_high_bg_target = 140
        let meal = AAPSMealData()
        func gate(_ bg: Double, _ profile: AAPSOapsProfile) -> Bool {
            AAPSDetermineBasalSMB.enableSMB(profile: profile, microBolusAllowed: true, meal: meal, targetBg: 100, bg: bg)
        }
        #expect(gate(119, p) == false)
        #expect(gate(139, p) == false)
        #expect(gate(140, p) == true)
        #expect(gate(220, p) == true)

        var off = p
        off.enableSMB_high_bg = false
        #expect(gate(220, off) == false)

        // SMB Always still wins, and microboluses stay off when the loop disallows them
        #expect(gate(90, Self.profile(smbAlways: true)) == true)
        #expect(
            AAPSDetermineBasalSMB
                .enableSMB(profile: p, microBolusAllowed: false, meal: meal, targetBg: 100, bg: 220) == false
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

    // MARK: - Recent TDD cap

    @Test("recent TDD cap only lowers") func recentTddCapOnlyLowers() {
        // over 1.2 x the 7-day: lowered to the cap
        let high = AAPSDynamicISF.cappedRecentTdd(150, tdd7D: 78, tdd1D: 90)
        #expect(high.capped)
        #expect(abs(high.value - 1.2 * 78) < 1E-12)
        // at or under the cap: untouched, never raised
        for recent in [0.0, 20, 60, 93.6] {
            let r = AAPSDynamicISF.cappedRecentTdd(recent, tdd7D: 78, tdd1D: 90)
            #expect(r.value == recent)
            #expect(!r.capped)
        }
        // no 7-day figure: yesterday is the reference
        let fallback = AAPSDynamicISF.cappedRecentTdd(150, tdd7D: nil, tdd1D: 70)
        #expect(fallback.capped)
        #expect(abs(fallback.value - 84) < 1E-12)
        // nothing to cap against
        let none = AAPSDynamicISF.cappedRecentTdd(150, tdd7D: nil, tdd1D: nil)
        #expect(none.value == 150)
        #expect(!none.capped)
        // across a sweep the result is never above the input
        for recent in stride(from: 0.0, through: 300, by: 7.5) {
            for tdd7 in [40.0, 78, 120] {
                #expect(AAPSDynamicISF.cappedRecentTdd(recent, tdd7D: tdd7, tdd1D: 60).value <= recent)
            }
        }
    }

    @Test("Dynamic ISF caps the recent-hours term after big boluses") func dynamicIsfRecentCap() {
        // the 10-26 evening shape: 7-day 78, yesterday 78, big dinner boluses in the last 4 hours
        let inputs = AAPSDynamicISF.TddInputs(tdd1D: 78, tdd7D: 78, tddLast24H: 90, tddLast4H: 30, tddLast8to4H: 8)
        let r = AAPSDynamicISF.calculate(
            inputs: inputs, glucose: 223, adjustmentFactorPercent: 100, profileMultiplier: 1, insulinPeakMinutes: 75
        )
        let uncappedRecent = (1.4 * 30 + 0.6 * 8) * 3
        let uncapped = uncappedRecent * 0.33 + 78 * 0.34 + 78 * 0.33
        let capped = 1.2 * 78 * 0.33 + 78 * 0.34 + 78 * 0.33
        #expect(r.recentTddCapped)
        #expect(abs(r.tdd! - capped) < 1E-9)
        #expect(r.tdd! < uncapped)
        #expect(r.variableSensitivity == AAPSDynamicISF.roundToTenth(1800 / (capped * log(223.0 / 55 + 1))))

        // a normal day is unchanged
        let normal = AAPSDynamicISF.TddInputs(tdd1D: 78, tdd7D: 78, tddLast24H: 78, tddLast4H: 12, tddLast8to4H: 10)
        let n = AAPSDynamicISF.calculate(
            inputs: normal, glucose: 150, adjustmentFactorPercent: 100, profileMultiplier: 1, insulinPeakMinutes: 75
        )
        #expect(!n.recentTddCapped)
        #expect(abs(n.tdd! - ((1.4 * 12 + 0.6 * 10) * 3 * 0.33 + 78 * 0.34 + 78 * 0.33)) < 1E-9)
    }

    // MARK: - Low guard and upcoming carbs

    /// IOB ticks with a constant activity, as a large recent bolus gives for the first hours.
    static func activeIob(_ iob: Double, activity: Double) -> [AAPSIobTotal] {
        (0 ..< 48).map { i in
            AAPSIobTotal(
                time: now + Int64(i) * 300_000, iob: iob, activity: activity, lastBolusTime: 0,
                iobWithZeroTemp: .init(iob: iob, activity: activity)
            )
        }
    }

    static func runGuard(
        bg: Double,
        delta: Double,
        iob: Double,
        activity: Double,
        meal: AAPSMealData,
        upcoming: Double,
        profile: AAPSOapsProfile = profile(smbMinutes: 120, uamMinutes: 120)
    ) -> AAPSResult {
        AAPSDetermineBasalSMB.determineBasal(
            glucoseStatus: AAPSGlucoseStatus(glucose: bg, delta: delta, shortAvgDelta: delta, longAvgDelta: delta, date: now),
            currenttemp: AAPSCurrentTemp(),
            iobDataArray: activeIob(iob, activity: activity),
            profile: profile,
            autosensData: AAPSAutosensResult(),
            mealData: meal,
            microBolusAllowed: true,
            currentTime: now,
            flatBGsDetected: false,
            dynIsfMode: false,
            guardUpcomingCarbs: upcoming,
            timeZone: TimeZone(identifier: "UTC")!
        )
    }

    @Test("upcoming fat/protein releases a false low guard block") func upcomingCarbsReleaseGuard() {
        // BG 230 rising, insulin from a big meal bolus acting, 20 g COB left of 60 g eaten an hour ago,
        // and 50 g of fat/protein equivalents entered for the next hours
        let meal = AAPSMealData(carbs: 60, mealCOB: 20, lastCarbTime: Self.now - 60 * 60000)
        let blocked = Self.runGuard(bg: 230, delta: 2, iob: 3, activity: 0.02, meal: meal, upcoming: 0)
        #expect(blocked.trace.minGuardBG < blocked.trace.threshold, "\(blocked.reason)")
        #expect(blocked.rate == 0)
        #expect(blocked.units == nil)
        #expect(blocked.reason.contains("minGuardBG \(AAPSFormat.convertBg(blocked.trace.minGuardBG)) <"))

        let released = Self.runGuard(bg: 230, delta: 2, iob: 3, activity: 0.02, meal: meal, upcoming: 50)
        #expect(released.trace.guardReleasedByUpcomingCarbs, "\(released.reason)")
        #expect(released.trace.guardBG >= released.trace.threshold)
        #expect(released.reason.contains("upcoming fat/protein 50g: guard minGuardBG"))
        // the zero-temp suspend still follows the unmodified guard: only SMBs may come back
        #expect(released.rate == 0)
        #expect(released.reason.contains("minGuardBG \(AAPSFormat.convertBg(blocked.trace.minGuardBG)) <"))
        // the guard's figure is the only thing that moved
        #expect(released.trace.minGuardBG == blocked.trace.minGuardBG)
        #expect(released.eventualBG == blocked.eventualBG)
        #expect(released.trace.minPredBG == blocked.trace.minPredBG)
        #expect(released.COB == blocked.COB)
        #expect(released.predCOB == blocked.predCOB)
        #expect(released.predUAM == blocked.predUAM)

        // with the setting off (no grams passed) it is AAPS exactly
        #expect(Self.runGuard(bg: 230, delta: 2, iob: 3, activity: 0.02, meal: meal, upcoming: 0) == blocked)
    }

    @Test("future carbs never raise insulinReq above the no-future-carbs result") func upcomingCarbsNeverRaiseDose() {
        var released = 0
        for bg in [150.0, 185, 230, 290] {
            for delta in [-6.0, -2, 0, 3, 8] {
                for activity in [0.0, 0.01, 0.025, 0.05] {
                    for mealCOB in [0.0, 15, 40] {
                        for upcoming in [10.0, 40, 90] {
                            let meal = mealCOB > 0
                                ? AAPSMealData(carbs: mealCOB + 20, mealCOB: mealCOB, lastCarbTime: Self.now - 45 * 60000)
                                : AAPSMealData()
                            let base = Self.runGuard(
                                bg: bg,
                                delta: delta,
                                iob: activity * 120,
                                activity: activity,
                                meal: meal,
                                upcoming: 0
                            )
                            let with = Self.runGuard(
                                bg: bg, delta: delta, iob: activity * 120, activity: activity, meal: meal, upcoming: upcoming
                            )
                            let label = "bg \(bg) delta \(delta) act \(activity) cob \(mealCOB) +\(upcoming)g"
                            // predictions, eventual BG and COB never see the upcoming carbs
                            #expect(with.eventualBG == base.eventualBG, "\(label)")
                            #expect(with.trace.minPredBG == base.trace.minPredBG, "\(label)")
                            #expect(with.trace.minGuardBG == base.trace.minGuardBG, "\(label)")
                            #expect(with.COB == base.COB, "\(label)")
                            #expect(with.trace.guardBG >= base.trace.guardBG, "\(label)")
                            if with.trace.guardReleasedByUpcomingCarbs {
                                released += 1
                                // released: the insulinReq is what AAPS worked out without the carbs,
                                // never more, and max IOB still caps it
                                let maxReq = AAPSFormat.round(
                                    (min(base.trace.minPredBG, base.trace.eventualBG) - base.trace.targetBG) / base.trace.sens, 2
                                )
                                #expect((with.insulinReq ?? 0) <= max(0, maxReq) + 1E-9, "\(label)")
                                #expect((with.insulinReq ?? 0) <= 10 - activity * 120 + 1E-9, "\(label)")
                                #expect((with.units ?? 0) <= (with.trace.maxBolus ?? 0) + 1E-9, "\(label)")
                                #expect((with.rate ?? 0) <= AAPSDetermineBasalSMB.maxSafeBasal(Self.profile()), "\(label)")
                            } else {
                                // not released: the decision is AAPS's exactly
                                #expect(with.trace.enableSMB == base.trace.enableSMB, "\(label)")
                                #expect(with.insulinReq == base.insulinReq, "\(label)")
                                #expect(with.units == base.units, "\(label)")
                                #expect(with.rate == base.rate, "\(label)")
                                #expect(with.duration == base.duration, "\(label)")
                            }
                        }
                    }
                }
            }
        }
        #expect(released > 0, "the sweep must include released blocks")
    }

    @Test("falling or under 150 is never released") func upcomingCarbsNeedHighSteadyBG() {
        let meal = AAPSMealData(carbs: 60, mealCOB: 20, lastCarbTime: Self.now - 60 * 60000)
        #expect(
            !Self.runGuard(bg: 230, delta: -2, iob: 3, activity: 0.02, meal: meal, upcoming: 50).trace
                .guardReleasedByUpcomingCarbs
        )
        #expect(
            !Self.runGuard(bg: 140, delta: 2, iob: 3, activity: 0.02, meal: meal, upcoming: 50).trace
                .guardReleasedByUpcomingCarbs
        )
    }

    @Test("a real low still blocks: BG under the threshold is never released") func upcomingCarbsKeepRealLowBlock() {
        let meal = AAPSMealData(carbs: 30, mealCOB: 10, lastCarbTime: Self.now - 30 * 60000)
        let r = Self.runGuard(bg: 65, delta: -3, iob: 2, activity: 0.015, meal: meal, upcoming: 90)
        #expect(!r.trace.guardReleasedByUpcomingCarbs)
        #expect(r.rate == 0)
        #expect(r.units == nil)
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
        #expect(!decoded.guardSeesUpcomingCarbs) // missing key: off
        #expect(!AAPSDosingSettings.default.guardSeesUpcomingCarbs)
        let off = try JSONDecoder().decode(AAPSDosingSettings.self, from: Data(#"{"guardSeesUpcomingCarbs":false}"#.utf8))
        #expect(!off.guardSeesUpcomingCarbs)
        let junk = try JSONDecoder().decode(AAPSDosingSettings.self, from: Data(#"{"guardSeesUpcomingCarbs":"yes"}"#.utf8))
        #expect(!junk.guardSeesUpcomingCarbs)
        let roundTrip = try JSONDecoder().decode(AAPSDosingSettings.self, from: JSONEncoder().encode(off))
        #expect(roundTrip == off)
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

/// Made-up numbers only. The observed-insulin-effect correction (Trio addition to the AAPS mode).
@Suite("AAPS dosing observed insulin effect") struct AAPSObservedInsulinEffectTests {
    typealias S = AAPSDosingSyntheticTests
    typealias Limits = AAPSDetermineBasalSMB.ObservedInsulinEffect

    static let activity = 0.015 // at ISF 50 the insulin alone drops BG 3.75 per 5 minutes, 33.75 over 45

    /// The window as the adapter hands it over: flat insulin activity, BG `drop` lower 45 minutes ago.
    static func effect(observed: Double, bg: Double = 230, activity: Double = activity) -> AAPSObservedInsulinEffect {
        AAPSObservedInsulinEffect(glucoseThen: bg - observed, activities: Array(repeating: activity, count: 9))
    }

    static func run(
        bg: Double = 230,
        delta: Double = 0,
        iob: Double = 3,
        activity: Double = activity,
        ticks: [AAPSIobTotal]? = nil,
        effect: AAPSObservedInsulinEffect?
    ) -> AAPSResult {
        AAPSDetermineBasalSMB.determineBasal(
            glucoseStatus: AAPSGlucoseStatus(glucose: bg, delta: delta, shortAvgDelta: delta, longAvgDelta: delta, date: S.now),
            currenttemp: AAPSCurrentTemp(),
            iobDataArray: ticks ?? S.activeIob(iob, activity: activity),
            profile: S.profile(smbMinutes: 120, uamMinutes: 120),
            autosensData: AAPSAutosensResult(),
            mealData: AAPSMealData(),
            microBolusAllowed: true,
            currentTime: S.now,
            flatBGsDetected: false,
            dynIsfMode: false,
            observedInsulinEffect: effect,
            timeZone: TimeZone(identifier: "UTC")!
        )
    }

    /// The port at a fixed insulin scale, no gates.
    static func scaled(bg: Double, delta: Double, iob: Double, activity: Double, scale: Double) -> AAPSResult {
        AAPSDetermineBasalSMB.determineBasalScaled(
            glucoseStatus: AAPSGlucoseStatus(glucose: bg, delta: delta, shortAvgDelta: delta, longAvgDelta: delta, date: S.now),
            currenttemp: AAPSCurrentTemp(),
            iobDataArray: S.activeIob(iob, activity: activity),
            profile: S.profile(smbMinutes: 120, uamMinutes: 120),
            autosensData: AAPSAutosensResult(),
            mealData: AAPSMealData(),
            microBolusAllowed: true,
            currentTime: S.now,
            flatBGsDetected: false,
            dynIsfMode: false,
            isfTiersEnabled: false,
            isfTiers: AAPSIsfTiers.defaults,
            autosensMin: 0.7,
            isfTiersOnDynamic: false,
            guardUpcomingCarbs: 0,
            insulinScale: scale,
            timeZone: TimeZone(identifier: "UTC")!
        )
    }

    @Test("the ratio never goes above 1 or below 0.5") func ratioClamp() {
        for observed in stride(from: -120.0, through: 60, by: 2.5) {
            for activity in [0.004, 0.01, 0.015, 0.03, 0.08] {
                guard let r = AAPSDetermineBasalSMB.observedInsulinEffectRatio(
                    bg: 230, effect: Self.effect(observed: observed, activity: activity), sens: 50
                ) else {
                    // only a predicted drop under 15 mg/dL is too small to use
                    #expect(9 * AAPSFormat.round(activity * 50 * 5, 2) < Limits.minPredictedDrop)
                    continue
                }
                #expect(r <= 1)
                #expect(r >= 0.5)
            }
        }
        // a fall as big as predicted, or bigger, leaves the insulin effect as it is
        #expect(AAPSDetermineBasalSMB.observedInsulinEffectRatio(bg: 230, effect: Self.effect(observed: -33.75), sens: 50) == 1)
        #expect(AAPSDetermineBasalSMB.observedInsulinEffectRatio(bg: 230, effect: Self.effect(observed: -80), sens: 50) == 1)
        // rising while insulin should have dropped it: the floor
        #expect(AAPSDetermineBasalSMB.observedInsulinEffectRatio(bg: 230, effect: Self.effect(observed: 10), sens: 50) == 0.5)
        let r = AAPSDetermineBasalSMB.observedInsulinEffectRatio(bg: 230, effect: Self.effect(observed: -20.925), sens: 50)
        #expect(abs((r ?? 0) - 0.62) < 1E-9)
    }

    @Test("a false low block is released with the insulin effect weakened") func releasesFalseBlock() {
        let unscaled = Self.run(effect: nil)
        #expect(unscaled.trace.minGuardBG < unscaled.trace.threshold, "\(unscaled.reason)")
        #expect(unscaled.trace.nearGuardBG >= unscaled.trace.threshold)
        #expect(unscaled.units == nil)

        let half = Self.run(effect: Self.effect(observed: 0))
        #expect(half.trace.observedInsulinEffect == 0.5)
        #expect(half.reason.contains("observed insulin effect x0.5; "), "\(half.reason)")
        #expect(half.trace.minGuardBG >= half.trace.threshold, "\(half.reason)")
        #expect((half.units ?? 0) > 0, "\(half.reason)")
        #expect((half.eventualBG ?? 0) > (unscaled.eventualBG ?? 0))
        #expect(half.trace.minPredBG >= unscaled.trace.minPredBG)

        let partial = Self.run(effect: Self.effect(observed: -20.925))
        #expect(abs(partial.trace.observedInsulinEffect - 0.62) < 1E-9)
        #expect(partial.reason.contains("observed insulin effect x0.62; "), "\(partial.reason)")
    }

    @Test("each gate blocks the correction") func gatesBlock() {
        let flat = Self.effect(observed: 0)
        func untouched(_ r: AAPSResult, _ label: String) {
            #expect(r.trace.observedInsulinEffect == 1, "\(label)")
            #expect(!r.reason.contains("observed insulin effect"), "\(label)")
        }
        // BG 170
        let low = Self.run(bg: 170, effect: Self.effect(observed: 0, bg: 170))
        untouched(low, "bg 170")
        #expect(low == Self.run(bg: 170, effect: nil))
        // falling 4 per 5 minutes
        let falling = Self.run(delta: -4, effect: flat)
        untouched(falling, "falling 4")
        #expect(falling == Self.run(delta: -4, effect: nil))
        // falling exactly 3 is still allowed
        #expect(Self.run(delta: -3, effect: flat).trace.observedInsulinEffect == 0.5)
        // near a low within 45 minutes: a fresh bolus about to peak, the unscaled guard dips in the first 45 min
        var ticks = S.activeIob(8, activity: 0.1)
        ticks[0].activity = 0.015
        let nearLow = Self.run(bg: 190, delta: -3, ticks: ticks, effect: Self.effect(observed: 0, bg: 190))
        let nearLowBase = Self.run(bg: 190, delta: -3, ticks: ticks, effect: nil)
        #expect(nearLowBase.trace.nearGuardBG < nearLowBase.trace.threshold, "\(nearLowBase.reason)")
        untouched(nearLow, "near low")
        #expect(nearLow == nearLowBase)
        // predicted drop too small to measure
        let tiny = Self.run(effect: Self.effect(observed: 0, activity: 0.005))
        untouched(tiny, "tiny predicted drop")
    }

    // MARK: - Adapter data gates

    static let curve = AAPSIob.Curve(diaHours: 5, peakMinutes: 75)

    static func history(gapMinutes: Int? = nil, siteChangeMinutesAgo: Int? = nil) -> AAPSHistory {
        var h = AAPSHistory()
        h.boluses = [AAPSHistory.Bolus(time: S.now - 60 * 60000, amount: 4)]
        h.basalSchedule = [AAPSHistory.BasalEntry(minutes: 0, rate: 1)]
        h.temps = [AAPSHistory.TempBasal(time: S.now - 6 * 3_600_000, duration: 6 * 3_600_000, rate: 1)]
        h.glucose = (0 ... 14).compactMap { k -> AAPSHistory.Glucose? in
            let minutesAgo = k * 5
            if let gap = gapMinutes, minutesAgo > 10, minutesAgo < 10 + gap { return nil }
            return AAPSHistory.Glucose(time: S.now - Int64(minutesAgo) * 60000 - 20000, value: 230)
        }
        if let ago = siteChangeMinutesAgo { h.siteChanges = [S.now - Int64(ago) * 60000] }
        return h
    }

    static func adapterEffect(_ h: AAPSHistory) -> AAPSObservedInsulinEffect? {
        AAPSDosingAdapter.observedInsulinEffect(
            history: h, now: S.now, autosensRatio: 1, curve: curve, calendar: Calendar(identifier: .gregorian)
        )
    }

    @Test("clean history gives the 45-minute window") func adapterWindow() {
        let e = Self.adapterEffect(Self.history())
        #expect(e?.glucoseThen == 230)
        #expect(e?.activities.count == 9)
        // the last activity is the one the loop uses now
        let nowActivity = AAPSIob.total(
            at: S.now, now: S.now, ratio: 1, curve: Self.curve, history: Self.history(), includeZeroTemp: false,
            calendar: Calendar(identifier: .gregorian)
        ).activity
        #expect(e?.activities.last == nowActivity)
        #expect((e?.activities.first ?? 0) > 0)
    }

    @Test("a site change 2 hours ago blocks, 4 hours ago does not") func adapterSiteChange() {
        #expect(Self.adapterEffect(Self.history(siteChangeMinutesAgo: 120)) == nil)
        #expect(Self.adapterEffect(Self.history(siteChangeMinutesAgo: 240)) != nil)
        // the history builder counts primes and the stored pod changes
        let h = AAPSHistory.from(
            pumpHistory: [PumpHistoryEvent(
                id: "p",
                type: .prime,
                timestamp: Date(timeIntervalSince1970: Double(S.now) / 1000 - 3600)
            )],
            carbs: [],
            glucose: [],
            basalProfile: [],
            now: Date(timeIntervalSince1970: Double(S.now) / 1000),
            siteChanges: [Date(timeIntervalSince1970: Double(S.now) / 1000 - 7200)]
        )
        #expect(h.siteChanges == [S.now - 7_200_000, S.now - 3_600_000])
    }

    @Test("a glucose gap over 10 minutes blocks, one missed reading does not") func adapterGap() {
        #expect(Self.adapterEffect(Self.history(gapMinutes: 10)) != nil) // one reading missing: 10 min apart
        #expect(Self.adapterEffect(Self.history(gapMinutes: 15)) == nil) // two missing: 15 min apart
        var stale = Self.history()
        stale.glucose = stale.glucose.filter { $0.time < S.now - 40 * 60000 } // nothing recent
        #expect(Self.adapterEffect(stale) == nil)
        var short = Self.history()
        short.glucose = short.glucose.filter { $0.time > S.now - 30 * 60000 } // does not reach back 45 min
        #expect(Self.adapterEffect(short) == nil)
    }

    // MARK: - Off and bounds

    @Test("setting off gives today's output exactly") func offIsUnchanged() throws {
        #expect(AAPSDosingSettings.default.correctForecastFromObservedInsulinEffect)
        let missing = try JSONDecoder().decode(AAPSDosingSettings.self, from: Data(#"{"enabled":true}"#.utf8))
        #expect(missing.correctForecastFromObservedInsulinEffect) // missing key: on
        let off = try JSONDecoder()
            .decode(AAPSDosingSettings.self, from: Data(#"{"correctForecastFromObservedInsulinEffect":false}"#.utf8))
        #expect(!off.correctForecastFromObservedInsulinEffect)
        let junk = try JSONDecoder()
            .decode(AAPSDosingSettings.self, from: Data(#"{"correctForecastFromObservedInsulinEffect":"no"}"#.utf8))
        #expect(junk.correctForecastFromObservedInsulinEffect)
        #expect(try JSONDecoder().decode(AAPSDosingSettings.self, from: JSONEncoder().encode(off)) == off)

        // no window passed (setting off) is the port at scale 1, which is the unmodified AAPS port
        for bg in [120.0, 180, 230, 300] {
            for delta in [-5.0, 0, 4] {
                for activity in [0.0, 0.01, 0.03] {
                    let none = Self.run(bg: bg, delta: delta, iob: activity * 200, activity: activity, effect: nil)
                    let one = Self.scaled(bg: bg, delta: delta, iob: activity * 200, activity: activity, scale: 1)
                    #expect(none == one, "bg \(bg) delta \(delta) act \(activity)")
                    #expect(none.trace.observedInsulinEffect == 1)
                }
            }
        }
    }

    @Test("with the correction, insulinReq never exceeds the insulin-effect-halved result") func halfBound() {
        var applied = 0
        for bg in [180.0, 200, 230, 260, 300] {
            for delta in [-3.0, -1, 0, 2, 5] {
                for activity in [0.005, 0.01, 0.015, 0.02, 0.03, 0.05] {
                    for observed in [-30.0, -15, -5, 0, 10] {
                        let iob = activity * 200
                        let r = Self.run(
                            bg: bg, delta: delta, iob: iob, activity: activity,
                            effect: Self.effect(observed: observed, bg: bg, activity: activity)
                        )
                        let label = "bg \(bg) delta \(delta) act \(activity) obs \(observed)"
                        #expect(r.trace.observedInsulinEffect >= 0.5 && r.trace.observedInsulinEffect <= 1, "\(label)")
                        guard r.trace.observedInsulinEffect < 1 else { continue }
                        applied += 1
                        let half = Self.scaled(bg: bg, delta: delta, iob: iob, activity: activity, scale: 0.5)
                        #expect(max(0, r.insulinReq ?? 0) <= max(0, half.insulinReq ?? 0) + 1E-9, "\(label)")
                        // limits untouched
                        #expect((r.units ?? 0) <= (r.trace.maxBolus ?? 0) + 1E-9, "\(label)")
                        #expect((r.rate ?? 0) <= AAPSDetermineBasalSMB.maxSafeBasal(S.profile()) + 1E-9, "\(label)")
                        #expect((r.insulinReq ?? 0) <= 10 - iob + 1E-9, "\(label)")
                        #expect(
                            r.trace.threshold == Self.run(bg: bg, delta: delta, iob: iob, activity: activity, effect: nil)
                                .trace.threshold
                        )
                    }
                }
            }
        }
        #expect(applied > 0, "the sweep must include applied corrections")
    }
}
