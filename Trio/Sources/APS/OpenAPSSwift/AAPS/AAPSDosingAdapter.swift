import Foundation

/// Runs the AAPS dosing mode on Trio's inputs: maps Trio's profile, IOB, meal and glucose data
/// into the AAPS types, works out AAPS Dynamic ISF from the TDD figures Trio gathered, calls the
/// DetermineBasalSMB port, and turns the result back into a Trio `Determination`.
///
/// Mapping decisions (Trio has no exact equivalent for these AAPS inputs):
/// - Target: AAPS aims at the midpoint of `min_bg` and `max_bg`. Trio's target is a single value
///   (low equals high), so the midpoint is that target. An active override target replaces both,
///   as it does in stock Trio. A temp target arrives through the profile, as in stock Trio.
/// - Overrides: AAPS scales basal, ISF and carb ratio with the profile percentage, and multiplies
///   the Dynamic ISF TDD by it. Trio's override percentage maps onto the same places, honouring
///   its ISF and CR switches. Basal is scaled always, as stock Trio does.
/// - LGS threshold: Trio's "Minimal Safety Threshold" setting is AAPS's `lgsThreshold`.
/// - Insulin divisor: from the insulin peak (custom peak if set, else 75 for rapid acting and
///   55 for ultra rapid).
/// - SMB off by override or schedule turns AAPS's `microBolusAllowed` off.
/// - Flat-CGM detection: AAPS only flags it for Libre 1 sensors, so it is off here.
/// - Autosens: with Dynamic ISF running, AAPS's TDD-based ratio. Otherwise Trio's autosens ratio,
///   standing in for AAPS's own autosens plugin.
/// - Temp basal rates are rounded down to a rate the pump supports, as Trio's enactment would do.
/// - Inputs: when the loop passes Trio's history (`context.history`, always in the app), IOB, COB
///   and glucose status are AAPS's own calculations on that history (`AAPSIob`,
///   `AAPSMealCalculator`, `AAPSGlucoseStatusCalculator`), with temp basal IOB counted against the
///   scheduled basal times the autosens ratio above, and carbs absorbed at the 24 h average dynamic
///   ISF of recent runs (`AAPSCarbIsfCache`). Without it, Trio's own IOB, meal and glucose status
///   are mapped across.
/// - Upcoming carbs (Trio addition, setting "Guard sees upcoming fat/protein"): carb entries already
///   entered but dated up to 4 hours ahead, which is how Trio stores fat and protein equivalents,
///   are handed to DetermineBasalSMB for the low-glucose guard only (`guardUpcomingCarbs`).
enum AAPSDosingAdapter {
    private static func dbl(_ d: Decimal) -> Double { Double(truncating: d as NSNumber) }

    /// Exact short decimal for a Double (0.35, not 0.34999999999999997763).
    private static func dec(_ x: Double) -> Decimal { Decimal(string: "\(x)") ?? Decimal(x) }

    static func insulinPeakMinutes(profile: Profile) -> Double {
        if profile.useCustomPeakTime { return dbl(profile.insulinPeakTime) }
        switch profile.curve {
        case .ultraRapid: return 55
        default: return 75
        }
    }

    struct Prepared {
        let glucoseStatus: AAPSGlucoseStatus
        let currentTemp: AAPSCurrentTemp
        let iobArray: [AAPSIobTotal]
        let profile: AAPSOapsProfile
        let autosens: AAPSAutosensResult
        let meal: AAPSMealData
        let microBolusAllowed: Bool
        let dynIsfMode: Bool
        let tiersEnabled: Bool
        let tiers: [AAPSIsfTiers.Tier]
        let autosensMin: Double
        let tiersOnDynamic: Bool
        let tdd: Double?
        let recentTddCapped: Bool
        let guardUpcomingCarbs: Double
    }

    /// AAPS Dynamic ISF for this run (the plugin's `calculateRawDynIsf`).
    static func dynamicIsf(
        context: AAPSDosingContext,
        profile: Profile,
        glucose: Double,
        trioCustomOrefVariables vars: TrioCustomOrefVariables
    ) -> AAPSDynamicISF.Result {
        let overrideScalesIsf = vars.useOverride && (vars.isf || vars.isfAndCr)
        return AAPSDynamicISF.calculate(
            inputs: context.tdd,
            glucose: glucose,
            adjustmentFactorPercent: context.settings.adjustmentFactorPercent,
            profileMultiplier: overrideScalesIsf ? dbl(vars.overrideFactor()) : 1.0,
            insulinPeakMinutes: insulinPeakMinutes(profile: profile)
        )
    }

    /// Records this run's dynamic ISF in the carb ISF cache, keyed the way AAPS keys it.
    /// Unchanged when Dynamic ISF is off or did not run.
    static func updatedCarbIsfCache(
        context: AAPSDosingContext,
        profile: Profile,
        trioCustomOrefVariables vars: TrioCustomOrefVariables,
        currentTime: Date
    ) -> AAPSCarbIsfCache? {
        guard context.settings.dynamicISF, let history = context.history else { return nil }
        let nowMs = Int64((currentTime.timeIntervalSince1970 * 1000).rounded())
        guard let gs = AAPSGlucoseStatusCalculator.glucoseStatus(
            buckets: AAPSGlucoseStatusCalculator.bucketedData(history.glucose),
            now: nowMs
        ) else { return nil }
        let dyn = dynamicIsf(context: context, profile: profile, glucose: gs.glucose, trioCustomOrefVariables: vars)
        guard dyn.partsCalculated, let variableSensitivity = dyn.variableSensitivity else { return nil }
        var cache = context.carbIsfCache ?? AAPSCarbIsfCache()
        cache.record(time: nowMs, glucose: gs.glucose, variableSensitivity: variableSensitivity)
        return cache
    }

    static func prepare(
        context: AAPSDosingContext,
        profile: Profile,
        currentTemp: TempBasal,
        iobData: [IobResult],
        mealData: ComputedCarbs,
        autosensData: Autosens,
        glucoseStatus: GlucoseStatus,
        microBolusAllowed: Bool,
        trioCustomOrefVariables: TrioCustomOrefVariables,
        currentTime: Date
    ) throws -> Prepared {
        let settings = context.settings
        guard let currentBasal = profile.currentBasal, let maxBasal = profile.maxBasal, let maxDailyBasal = profile.maxDailyBasal
        else { throw DeterminationError.missingCurrentBasal }

        let vars = trioCustomOrefVariables
        let overrideFactor = vars.overrideFactor()

        var minBg = dbl(profile.minBg ?? 100)
        var maxBg = dbl(profile.maxBg ?? profile.minBg ?? 100)
        if let target = profile.profileTarget(trioCustomOrefVariables: vars), vars.useOverride,
           vars.overrideTarget != 0, vars.overrideTarget != 6, !(profile.temptargetSet ?? false)
        {
            minBg = dbl(target)
            maxBg = dbl(target)
        }

        let sens = dbl(profile.profileSensitivity(at: currentTime, trioCustomOrefVaribales: vars))
        var carbRatio = profile.carbRatio ?? profile.carbRatioFor(time: currentTime)
        if vars.useOverride, vars.cr || vars.isfAndCr { carbRatio /= overrideFactor }

        var smbMinutes = profile.maxSMBBasalMinutes
        var uamMinutes = profile.maxUAMSMBBasalMinutes
        if vars.useOverride, vars.advancedSettings {
            smbMinutes = vars.smbMinutes
            uamMinutes = vars.uamMinutes
        }

        // With Trio's history in AAPS's shape, glucose status comes from AAPS's bucketing.
        let nowMs = Int64((currentTime.timeIntervalSince1970 * 1000).rounded())
        let buckets = context.history.flatMap { AAPSGlucoseStatusCalculator.bucketedData($0.glucose) }
        let aapsGlucoseStatus = AAPSGlucoseStatusCalculator.glucoseStatus(buckets: buckets, now: nowMs)
        let mappedGlucoseStatus = aapsGlucoseStatus ?? AAPSGlucoseStatus(
            glucose: dbl(glucoseStatus.glucose),
            noise: Double(glucoseStatus.noise),
            delta: dbl(glucoseStatus.delta),
            shortAvgDelta: dbl(glucoseStatus.shortAvgDelta),
            longAvgDelta: dbl(glucoseStatus.longAvgDelta),
            date: Int64(glucoseStatus.date.timeIntervalSince1970 * 1000)
        )

        let glucose = mappedGlucoseStatus.glucose
        let dyn = dynamicIsf(context: context, profile: profile, glucose: glucose, trioCustomOrefVariables: vars)
        let dynIsfMode = settings.dynamicISF && dyn.partsCalculated && dyn.variableSensitivity != nil

        let autosens: AAPSAutosensResult
        if dynIsfMode, let tddAutosens = AAPSDynamicISF.autosens(
            inputs: context.tdd,
            adjustSensitivity: settings.adjustSensitivityFromTDD
        ) {
            autosens = tddAutosens
        } else {
            autosens = AAPSAutosensResult(ratio: dbl(autosensData.ratio))
        }

        let oaps = AAPSOapsProfile(
            max_iob: dbl(profile.maxIob),
            max_daily_basal: dbl(maxDailyBasal),
            max_basal: dbl(maxBasal),
            min_bg: minBg,
            max_bg: maxBg,
            target_bg: (minBg + maxBg) / 2,
            carb_ratio: dbl(carbRatio),
            sens: sens,
            max_daily_safety_multiplier: dbl(profile.maxDailySafetyMultiplier),
            current_basal_safety_multiplier: dbl(profile.currentBasalSafetyMultiplier),
            high_temptarget_raises_sensitivity: profile.highTemptargetRaisesSensitivity,
            low_temptarget_lowers_sensitivity: profile.lowTemptargetLowersSensitivity,
            sensitivity_raises_target: profile.sensitivityRaisesTarget,
            resistance_lowers_target: profile.resistanceLowersTarget,
            adv_target_adjustments: false,
            exercise_mode: false,
            half_basal_exercise_target: Int(dbl(profile.halfBasalExerciseTarget)),
            skip_neutral_temps: profile.skipNeutralTemps,
            remainingCarbsCap: Int(dbl(profile.remainingCarbsCap)),
            enableUAM: profile.enableUAM,
            SMBInterval: Int(dbl(profile.smbInterval)),
            enableSMB_with_COB: profile.enableSMBWithCOB,
            enableSMB_with_temptarget: profile.enableSMBWithTemptarget,
            allowSMB_with_high_temptarget: profile.allowSMBWithHighTemptarget,
            enableSMB_always: profile.enableSMBAlways,
            enableSMB_after_carbs: profile.enableSMBAfterCarbs,
            maxSMBBasalMinutes: Int(dbl(smbMinutes)),
            maxUAMSMBBasalMinutes: Int(dbl(uamMinutes)),
            bolus_increment: dbl(profile.bolusIncrement),
            carbsReqThreshold: Int(dbl(profile.carbsReqThreshold)),
            current_basal: dbl(currentBasal * overrideFactor),
            temptargetSet: profile.temptargetSet ?? false,
            autosens_max: dbl(profile.autosensMax),
            lgsThreshold: Int(dbl(profile.thresholdSetting)),
            variable_sens: dynIsfMode ? (dyn.variableSensitivity ?? 0) : 0,
            insulinDivisor: dyn.insulinDivisor,
            TDD: dyn.tdd ?? 0,
            enableSMB_high_bg: profile.enableSMBHighBg,
            enableSMB_high_bg_target: dbl(profile.enableSMBHighBgTarget)
        )

        var iobArray = iobData.enumerated().map { index, tick in
            AAPSIobTotal(
                time: Int64(tick.time.timeIntervalSince1970 * 1000),
                iob: dbl(tick.iob),
                activity: dbl(tick.activity),
                lastBolusTime: index == 0 ? Int64(iobData[0].lastBolusTime ?? 0) : 0,
                iobWithZeroTemp: AAPSIobTotal.ZeroTemp(
                    iob: dbl(tick.iobWithZeroTemp.iob),
                    activity: dbl(tick.iobWithZeroTemp.activity)
                )
            )
        }
        var meal = AAPSMealData(
            carbs: dbl(mealData.carbs),
            mealCOB: dbl(mealData.mealCOB),
            slopeFromMaxDeviation: dbl(mealData.slopeFromMaxDeviation),
            slopeFromMinDeviation: dbl(mealData.slopeFromMinDeviation),
            lastBolusTime: 0,
            lastCarbTime: Int64(mealData.lastCarbTime)
        )

        // AAPS's own IOB and COB from Trio's history: temp basals counted against the scheduled
        // basal times the autosens ratio the dosing uses, COB from the Oref1 carb chain.
        if let history = context.history {
            let curve = AAPSIob.Curve(
                diaHours: max(dbl(profile.dia ?? 5), 5),
                peakMinutes: IobCalculation.lookupPeak(
                    curve: profile.curve,
                    useCustomPeakTime: profile.useCustomPeakTime,
                    insulinPeakTime: profile.insulinPeakTime
                ) ?? 75
            )
            iobArray = AAPSIob.iobArray(history: history, now: nowMs, autosensRatio: autosens.ratio, curve: curve)
            let cache = context.carbIsfCache
            let isfForCarbs: (Int64) -> Double = { t in
                let date = Date(timeIntervalSince1970: Double(t) / 1000)
                let profileIsf = dbl(vars.override(sensitivity: profile.sensitivityFor(time: date)))
                guard dynIsfMode else { return profileIsf }
                return cache?.average(upTo: t) ?? profileIsf
            }
            let carbRatioAt: (Int64) -> Double = { t in
                var cr = profile.carbRatioFor(time: Date(timeIntervalSince1970: Double(t) / 1000))
                if vars.useOverride, vars.cr || vars.isfAndCr { cr /= overrideFactor }
                return dbl(cr)
            }
            let mealSettings = AAPSMealCalculator.Settings(
                min5mCarbImpact: dbl(profile.min5mCarbImpact),
                absorptionCutoffHours: dbl(profile.maxMealAbsorptionTime)
            )
            let table = AAPSMealCalculator.autosensTable(
                history: history,
                buckets: buckets ?? [],
                now: nowMs,
                curve: curve,
                isfForCarbs: isfForCarbs,
                carbRatio: carbRatioAt,
                settings: mealSettings
            )
            meal = AAPSMealCalculator.mealData(history: history, table: table, now: nowMs, settings: mealSettings)
        }

        var smbAllowed = microBolusAllowed && !vars.smbIsOff
        if smbAllowed, try DosingEngine.isSmbScheduledOff(trioCustomOrefVariables: vars, clock: currentTime) {
            smbAllowed = false
        }

        let upcomingCarbs = settings.guardSeesUpcomingCarbs
            ? (context.history?.upcomingCarbs ?? []).map(\.amount).reduce(0, +)
            : 0

        return Prepared(
            glucoseStatus: mappedGlucoseStatus,
            currentTemp: AAPSCurrentTemp(duration: currentTemp.duration, rate: dbl(currentTemp.rate), minutesrunning: nil),
            iobArray: iobArray,
            profile: oaps,
            autosens: autosens,
            meal: meal,
            microBolusAllowed: smbAllowed,
            dynIsfMode: dynIsfMode,
            tiersEnabled: vars.isfTiersEnabled && !vars.isfTiers.isEmpty,
            tiers: AAPSIsfTiers.fromTrio(vars.isfTiers),
            autosensMin: dbl(profile.autosensMin),
            tiersOnDynamic: settings.tierOrder == .onTopOfDynamic,
            tdd: dynIsfMode ? dyn.tdd : nil,
            recentTddCapped: dynIsfMode && dyn.recentTddCapped,
            guardUpcomingCarbs: upcomingCarbs
        )
    }

    static func determine(
        context: AAPSDosingContext,
        profile: Profile,
        currentTemp: TempBasal,
        iobData: [IobResult],
        mealData: ComputedCarbs,
        autosensData: Autosens,
        glucoseStatus: GlucoseStatus,
        microBolusAllowed: Bool,
        trioCustomOrefVariables: TrioCustomOrefVariables,
        currentTime: Date
    ) throws -> Determination {
        guard !iobData.isEmpty else { throw DeterminationError.missingIob }
        let p = try prepare(
            context: context,
            profile: profile,
            currentTemp: currentTemp,
            iobData: iobData,
            mealData: mealData,
            autosensData: autosensData,
            glucoseStatus: glucoseStatus,
            microBolusAllowed: microBolusAllowed,
            trioCustomOrefVariables: trioCustomOrefVariables,
            currentTime: currentTime
        )
        let rT = AAPSDetermineBasalSMB.determineBasal(
            glucoseStatus: p.glucoseStatus,
            currenttemp: p.currentTemp,
            iobDataArray: p.iobArray,
            profile: p.profile,
            autosensData: p.autosens,
            mealData: p.meal,
            microBolusAllowed: p.microBolusAllowed,
            currentTime: Int64(currentTime.timeIntervalSince1970 * 1000),
            flatBGsDetected: false,
            dynIsfMode: p.dynIsfMode,
            isfTiersEnabled: p.tiersEnabled,
            isfTiers: p.tiers,
            autosensMin: p.autosensMin,
            isfTiersOnDynamic: p.tiersOnDynamic,
            guardUpcomingCarbs: p.guardUpcomingCarbs
        )
        return determination(from: rT, prepared: p, profile: profile, currentTime: currentTime)
    }

    static func determination(
        from rT: AAPSResult,
        prepared p: AAPSDosingAdapter.Prepared,
        profile: Profile,
        currentTime: Date
    ) -> Determination {
        let t = rT.trace
        let ran = rT.eventualBG != nil // false on AAPS's bad-CGM early exits
        let rate = rT.rate.map { TempBasalFunctions.roundBasal(profile: profile, basalRate: dec($0)) }
        var mode = p.dynIsfMode ? "Dynamic ISF, TDD \(AAPSFormat.withoutZeros(p.tdd ?? 0))" : "profile ISF"
        if p.recentTddCapped { mode += ", recent TDD capped" }
        if p.tiersEnabled {
            mode += ", tiers " + (p.tiersOnDynamic ? "on top of dynamic" : "in Trio order") +
                " x\(AAPSFormat.withoutZeros(t.tierMultiplier))"
        }
        return Determination(
            id: UUID(),
            reason: "AAPS dosing (\(mode)): " + rT.reason,
            units: rT.units.map(dec),
            insulinReq: rT.insulinReq.map(dec),
            eventualBG: rT.eventualBG.map { Int($0) },
            sensitivityRatio: rT.sensitivityRatio.map(dec),
            rate: rate,
            duration: rT.duration.map { Decimal($0) },
            iob: rT.IOB.map(dec),
            cob: rT.COB.map(dec),
            predictions: ran ? Predictions(iob: rT.predIOB, zt: rT.predZT, cob: rT.predCOB, uam: rT.predUAM) : nil,
            deliverAt: currentTime,
            carbsReq: rT.carbsReq.map { Decimal($0) },
            temp: .absolute,
            bg: rT.bg.map(dec),
            reservoir: nil,
            isf: ran ? dec(AAPSFormat.round(t.sens, 1)) : nil,
            timestamp: currentTime,
            tdd: p.tdd.map { dec(AAPSFormat.round($0, 2)) },
            current_target: ran ? dec(t.targetBG) : nil,
            minDelta: ran ? dec(t.minDelta) : nil,
            expectedDelta: ran ? dec(t.expectedDelta) : nil,
            minGuardBG: ran ? dec(t.minGuardBG) : nil,
            minPredBG: ran ? dec(t.minPredBG) : nil,
            threshold: ran ? dec(t.threshold) : nil,
            carbRatio: ran ? dec(AAPSFormat.round(t.carbRatio, 1)) : nil,
            received: false
        )
    }
}
