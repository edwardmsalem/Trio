import Foundation

/// Line-by-line Swift port of `DetermineBasalSMB.determine_basal` from Eddie's AAPS fork
/// (`plugins/aps/src/main/kotlin/app/aaps/plugins/aps/openAPSSMB/DetermineBasalSMB.kt`,
/// release 42bb385ff4), including the fork's ISF tiers and carb-ratio tier.
///
/// It computes in Double like AAPS and keeps AAPS's rounding (`Math.round` half up) so its
/// doses can be proven identical to AAPS's logged decisions. Nothing here is Trio-specific:
/// `AAPSDosingAdapter` maps Trio's inputs in and the result back out.
///
/// Not ported: `adv_target_adjustments` (AAPS hard-codes it off) and the skip-neutral-temps
/// top-of-hour cancel uses the device time zone, as AAPS does.
///
/// Trio addition, off unless `guardUpcomingCarbs` > 0: the low-glucose guard (minGuardBG under
/// threshold stops SMBs and sets a zero temp) also gets a second minGuardBG worked out with those
/// grams of already-entered, future-dated carbs added to COB, and uses the higher of the two.
/// Nothing else sees these carbs: eventual BG, minPredBG, insulinReq, the SMB size, carbsReq and
/// the COB reported all come from AAPS's own numbers, and every other limit is unchanged.
///
/// Trio addition, only when `observedInsulinEffect` is passed (setting "Correct forecast from observed
/// insulin effect"): when glucose over the last 45 minutes fell by less than the insulin alone was
/// predicted to drop it, the insulin part of every forecast curve (IOB, COB, UAM, ZT and the naive
/// eventual BG) is scaled by observed drop / predicted drop, clamped to 0.5...1, so minGuardBG,
/// minPredBG and eventual BG all see the weaker effect. It only ever weakens the insulin effect. It
/// runs only at BG 180+, not falling faster than 3 mg/dL per 5 minutes, and when the unscaled guard
/// forecast stays above the threshold for the next 45 minutes. max IOB, the SMB size limits, max safe
/// basal and the threshold are unchanged.
enum AAPSDetermineBasalSMB {
    private typealias F = AAPSFormat

    private static func round(_ v: Double, _ d: Int) -> Double { F.round(v, d) }
    private static func round(_ v: Double) -> Int { F.roundInt(v) }

    static let normalTargetMgdl = 100.0

    /// Limits of the observed-insulin-effect correction (see the type comment).
    enum ObservedInsulinEffect {
        /// The window compared, in minutes.
        static let windowMinutes = 45
        /// The strongest weakening: the insulin effect is never scaled below half.
        static let minScale = 0.5
        static let minGlucose = 180.0
        /// Not falling faster than this, mg/dL per 5 minutes.
        static let minMinDelta = -3.0
        /// Below this predicted drop over the window, mg/dL, the ratio is noise and is not used.
        static let minPredictedDrop = 15.0
        /// No pod or site change within this many hours.
        static let siteChangeHours = 3.0
        /// Longest allowed gap between glucose readings in the window, in minutes: one missed
        /// reading (10 minutes) plus a minute for CGM timing jitter.
        static let maxGlucoseGapMinutes = 11.0
        /// How far from the window start the first reading may be, in minutes.
        static let startToleranceMinutes = 4.0
    }

    /// Observed glucose change over the window divided by the change the insulin alone was predicted
    /// to cause (the sum of the 5-minute BGIs at `sens`), clamped to `minScale`...1. A rise while
    /// insulin was predicted to lower glucose gives `minScale`. Nil when the predicted drop is too
    /// small to measure against.
    static func observedInsulinEffectRatio(bg: Double, effect: AAPSObservedInsulinEffect, sens: Double) -> Double? {
        let predicted = effect.activities.reduce(0.0) { $0 + round(-$1 * sens * 5, 2) }
        guard predicted <= -ObservedInsulinEffect.minPredictedDrop else { return nil }
        let observed = bg - effect.glucoseThen
        let ratio = observed >= 0 ? 0 : observed / predicted
        return min(1, max(ObservedInsulinEffect.minScale, ratio))
    }

    /// The factor for the insulin effect when every gate passes on the unscaled run, else nil.
    static func observedInsulinEffectScale(unscaled: AAPSResult, effect: AAPSObservedInsulinEffect) -> Double? {
        guard let bg = unscaled.bg else { return nil } // bad-CGM early exit, nothing was forecast
        let t = unscaled.trace
        guard bg >= ObservedInsulinEffect.minGlucose,
              t.minDelta >= ObservedInsulinEffect.minMinDelta,
              t.nearGuardBG >= t.threshold,
              let ratio = observedInsulinEffectRatio(bg: bg, effect: effect, sens: t.sens),
              ratio < 1
        else { return nil }
        return ratio
    }

    static func calculateExpectedDelta(targetBg: Double, eventualBg: Double, bgi: Double) -> Double {
        let fiveMinBlocks = Double((2 * 60) / 5)
        let targetDelta = targetBg - eventualBg
        return round(bgi + (targetDelta / fiveMinBlocks), 1)
    }

    static func enableSMB(
        profile: AAPSOapsProfile,
        microBolusAllowed: Bool,
        meal: AAPSMealData,
        targetBg: Double,
        bg: Double
    ) -> Bool {
        if !microBolusAllowed { return false }
        if !profile.allowSMB_with_high_temptarget, profile.temptargetSet, targetBg > normalTargetMgdl { return false }
        if profile.enableSMB_always { return true }
        if profile.enableSMB_with_COB, meal.mealCOB != 0.0 { return true }
        if profile.enableSMB_after_carbs, meal.carbs != 0.0 { return true }
        if profile.enableSMB_with_temptarget, profile.temptargetSet, targetBg < 100 { return true }
        // Trio's high glucose gate, same place in the order as Trio's own oref
        if profile.enableSMB_high_bg, bg >= profile.enableSMB_high_bg_target { return true }
        return false
    }

    static func maxSafeBasal(_ profile: AAPSOapsProfile) -> Double {
        min(
            profile.max_basal,
            min(
                profile.max_daily_safety_multiplier * profile.max_daily_basal,
                profile.current_basal_safety_multiplier * profile.current_basal
            )
        )
    }

    private static func appendReason(_ rT: inout AAPSResult, _ msg: String) {
        if !rT.reason.isEmpty { rT.reason += ". " }
        rT.reason += msg
    }

    static func setTempBasal(
        _ requestedRate: Double,
        _ duration: Int,
        _ profile: AAPSOapsProfile,
        _ rT: AAPSResult,
        _ currenttemp: AAPSCurrentTemp
    ) -> AAPSResult {
        var rT = rT
        let maxSafe = maxSafeBasal(profile)
        var rate = requestedRate
        if rate < 0 { rate = 0.0 } else if rate > maxSafe { rate = maxSafe }
        let suggestedRate = rate // round_basal is the identity in AAPS
        if currenttemp.duration > (duration - 10), currenttemp.duration <= 120,
           suggestedRate <= currenttemp.rate * 1.2, suggestedRate >= currenttemp.rate * 0.8, duration > 0
        {
            rT
                .reason +=
                " \(currenttemp.duration)m left and \(F.withoutZeros(currenttemp.rate)) ~ req \(F.withoutZeros(suggestedRate))U/hr: no temp required"
            return rT
        }
        if suggestedRate == profile.current_basal {
            if profile.skip_neutral_temps {
                if currenttemp.duration > 0 {
                    appendReason(&rT, "Suggested rate is same as profile rate, a temp basal is active, canceling current temp")
                    rT.duration = 0
                    rT.rate = 0.0
                    return rT
                } else {
                    appendReason(&rT, "Suggested rate is same as profile rate, no temp basal is active, doing nothing")
                    return rT
                }
            } else {
                appendReason(&rT, "Setting neutral temp basal of \(F.kt(profile.current_basal))U/hr")
                rT.duration = duration
                rT.rate = suggestedRate
                return rT
            }
        } else {
            rT.duration = duration
            rT.rate = suggestedRate
            return rT
        }
    }

    static func determineBasal(
        glucoseStatus: AAPSGlucoseStatus,
        currenttemp: AAPSCurrentTemp,
        iobDataArray: [AAPSIobTotal],
        profile: AAPSOapsProfile,
        autosensData: AAPSAutosensResult,
        mealData: AAPSMealData,
        microBolusAllowed: Bool,
        currentTime: Int64,
        flatBGsDetected: Bool,
        dynIsfMode: Bool,
        isfTiersEnabled: Bool = false,
        isfTiers: [AAPSIsfTiers.Tier] = AAPSIsfTiers.defaults,
        autosensMin: Double = 0.7,
        isfTiersOnDynamic: Bool = false,
        guardUpcomingCarbs: Double = 0,
        observedInsulinEffect: AAPSObservedInsulinEffect? = nil,
        timeZone: TimeZone = .current
    ) -> AAPSResult {
        let run = { (insulinScale: Double) in
            determineBasalScaled(
                glucoseStatus: glucoseStatus,
                currenttemp: currenttemp,
                iobDataArray: iobDataArray,
                profile: profile,
                autosensData: autosensData,
                mealData: mealData,
                microBolusAllowed: microBolusAllowed,
                currentTime: currentTime,
                flatBGsDetected: flatBGsDetected,
                dynIsfMode: dynIsfMode,
                isfTiersEnabled: isfTiersEnabled,
                isfTiers: isfTiers,
                autosensMin: autosensMin,
                isfTiersOnDynamic: isfTiersOnDynamic,
                guardUpcomingCarbs: guardUpcomingCarbs,
                insulinScale: insulinScale,
                timeZone: timeZone
            )
        }
        let unscaled = run(1)
        guard let effect = observedInsulinEffect,
              let scale = observedInsulinEffectScale(unscaled: unscaled, effect: effect)
        else { return unscaled }
        return run(scale)
    }

    /// The port itself. `insulinScale` multiplies the insulin effect of every forecast curve and of
    /// the naive eventual BG (1 is AAPS unchanged).
    // swiftlint:disable:next function_body_length cyclomatic_complexity function_parameter_count
    static func determineBasalScaled(
        glucoseStatus: AAPSGlucoseStatus,
        currenttemp: AAPSCurrentTemp,
        iobDataArray: [AAPSIobTotal],
        profile: AAPSOapsProfile,
        autosensData: AAPSAutosensResult,
        mealData: AAPSMealData,
        microBolusAllowed: Bool,
        currentTime: Int64,
        flatBGsDetected: Bool,
        dynIsfMode: Bool,
        isfTiersEnabled: Bool,
        isfTiers: [AAPSIsfTiers.Tier],
        autosensMin: Double,
        isfTiersOnDynamic: Bool,
        guardUpcomingCarbs: Double,
        insulinScale: Double,
        timeZone: TimeZone
    ) -> AAPSResult {
        var rT = AAPSResult()
        let deliverAt = currentTime
        let profileCurrentBasal = profile.current_basal
        var basal = profileCurrentBasal
        let systemTime = currentTime
        let bgTime = glucoseStatus.date
        let minAgo = round(Double(systemTime - bgTime) / 60.0 / 1000.0, 1)
        let bg = glucoseStatus.glucose
        let noise = glucoseStatus.noise

        if bg <= 10 || bg == 38.0 || noise >= 3 {
            rT.reason += "CGM is calibrating, in ??? state, or noise is high"
        }
        if minAgo > 12 || minAgo < -5 {
            rT
                .reason +=
                "If current system time \(systemTime) is correct, then BG data is too old. The last BG data was read \(F.kt(minAgo))m ago at \(bgTime)"
        } else if bg > 60, flatBGsDetected {
            rT.reason += "Error: CGM data is unchanged for the past ~45m"
        }
        if bg <= 10 || bg == 38.0 || noise >= 3 || minAgo > 12 || minAgo < -5 || (bg > 60 && flatBGsDetected) {
            if currenttemp.rate > basal {
                rT.reason += ". Replacing high temp basal of \(F.kt(currenttemp.rate)) with neutral temp of \(F.kt(basal))"
                rT.deliverAt = deliverAt
                rT.duration = 30
                rT.rate = basal
                return rT
            } else if currenttemp.rate == 0.0, currenttemp.duration > 30 {
                rT.reason += ". Shortening " + "\(currenttemp.duration)" + "m long zero temp to 30m. "
                rT.deliverAt = deliverAt
                rT.duration = 30
                rT.rate = 0.0
                return rT
            } else {
                rT.reason += ". Temp \(F.kt(currenttemp.rate)) <= current basal \(F.kt(round(basal, 2)))U/hr; doing nothing. "
                return rT
            }
        }

        let maxIob = profile.max_iob
        var targetBg = (profile.min_bg + profile.max_bg) / 2
        var minBg = profile.min_bg
        var maxBg = profile.max_bg

        var sensitivityRatio: Double
        let highTemptargetRaisesSensitivity = profile.exercise_mode || profile.high_temptarget_raises_sensitivity
        let normalTarget = normalTargetMgdl
        let halfBasalTarget = profile.half_basal_exercise_target

        if highTemptargetRaisesSensitivity && profile.temptargetSet && targetBg > normalTarget
            || profile.low_temptarget_lowers_sensitivity && profile.temptargetSet && targetBg < normalTarget
        {
            let c = Double(halfBasalTarget) - normalTarget
            sensitivityRatio = c / (c + targetBg - normalTarget)
            sensitivityRatio = min(sensitivityRatio, profile.autosens_max)
            sensitivityRatio = round(sensitivityRatio, 2)
        } else {
            sensitivityRatio = autosensData.ratio
        }
        basal = profile.current_basal * sensitivityRatio

        if !profile.temptargetSet {
            if profile.sensitivity_raises_target && autosensData.ratio < 1 || profile.resistance_lowers_target && autosensData
                .ratio > 1
            {
                minBg = round((minBg - 60) / autosensData.ratio, 0) + 60
                maxBg = round((maxBg - 60) / autosensData.ratio, 0) + 60
                var newTargetBg = round((targetBg - 60) / autosensData.ratio, 0) + 60
                newTargetBg = max(80.0, newTargetBg)
                targetBg = newTargetBg
            }
        }

        let iobArray = iobDataArray
        let iobData = iobArray[0]

        let tick: String = glucoseStatus.delta > -0.5 ? "+" + "\(round(glucoseStatus.delta))" : "\(round(glucoseStatus.delta))"
        let minDelta = min(glucoseStatus.delta, glucoseStatus.shortAvgDelta)
        let minAvgDelta = min(glucoseStatus.shortAvgDelta, glucoseStatus.longAvgDelta)
        let maxDelta = max(glucoseStatus.delta, max(glucoseStatus.shortAvgDelta, glucoseStatus.longAvgDelta))

        var tierMultiplier = 1.0
        var sens: Double
        if dynIsfMode {
            if !isfTiersEnabled {
                sens = profile.variable_sens
            } else if isfTiersOnDynamic {
                tierMultiplier = AAPSIsfTiers.multiplierFor(bg, isfTiers)
                sens = AAPSIsfTiers.applyToSensitivity(profile.variable_sens, bg, isfTiers)
            } else {
                tierMultiplier = AAPSIsfTiers.multiplierFor(bg, isfTiers)
                sens = AAPSIsfTiers.trioOrderedSensitivity(
                    profileSens: profile.sens,
                    dynamicSens: profile.variable_sens,
                    glucose: bg,
                    tiers: isfTiers,
                    autosensMin: autosensMin,
                    autosensMax: profile.autosens_max
                )
            }
        } else {
            sens = round(profile.sens / sensitivityRatio, 1)
            if isfTiersEnabled {
                tierMultiplier = AAPSIsfTiers.multiplierFor(bg, isfTiers)
                sens = AAPSIsfTiers.applyToSensitivity(sens, bg, isfTiers)
            }
        }

        let carbRatio = isfTiersEnabled ? AAPSIsfTiers.applyToCarbRatio(profile.carb_ratio, bg, isfTiers) : profile.carb_ratio

        let bgi = round(-iobData.activity * sens * 5, 2)
        var deviation = round(Double(30 / 5) * (minDelta - bgi))
        if deviation < 0 {
            deviation = round(Double(30 / 5) * (minAvgDelta - bgi))
            if deviation < 0 {
                deviation = round(Double(30 / 5) * (glucoseStatus.longAvgDelta - bgi))
            }
        }

        let naiveEventualBG: Double
        if dynIsfMode {
            naiveEventualBG = round(bg - (iobData.iob * sens * insulinScale), 0)
        } else {
            if iobData.iob > 0 { naiveEventualBG = round(bg - (iobData.iob * sens * insulinScale), 0) }
            else { naiveEventualBG = round(bg - (iobData.iob * min(sens, profile.sens) * insulinScale), 0) }
        }
        var eventualBG = naiveEventualBG + Double(deviation)

        if bg > maxBg, profile.adv_target_adjustments, !profile.temptargetSet {
            let adjustedMinBG = round(max(80.0, minBg - (bg - minBg) / 3.0), 0)
            let adjustedTargetBG = round(max(80.0, targetBg - (bg - targetBg) / 3.0), 0)
            let adjustedMaxBG = round(max(80.0, maxBg - (bg - maxBg) / 3.0), 0)
            if eventualBG > adjustedMinBG, naiveEventualBG > adjustedMinBG, minBg > adjustedMinBG { minBg = adjustedMinBG }
            if eventualBG > adjustedTargetBG, naiveEventualBG > adjustedTargetBG,
               targetBg > adjustedTargetBG { targetBg = adjustedTargetBG }
            if eventualBG > adjustedMaxBG, naiveEventualBG > adjustedMaxBG, maxBg > adjustedMaxBG { maxBg = adjustedMaxBG }
        }

        let expectedDelta = calculateExpectedDelta(targetBg: targetBg, eventualBg: eventualBG, bgi: bgi)

        var threshold = minBg - 0.5 * (minBg - 40)
        if let lgs = profile.lgsThreshold, Double(lgs) > threshold {
            threshold = Double(lgs)
        }

        rT = AAPSResult(
            bg: bg,
            tick: tick,
            eventualBG: eventualBG,
            targetBG: targetBg,
            insulinReq: 0.0,
            deliverAt: deliverAt,
            sensitivityRatio: sensitivityRatio,
            variable_sens: profile.variable_sens
        )

        var COBpredBGs: [Double] = [bg]
        var aCOBpredBGs: [Double] = [bg]
        var IOBpredBGs: [Double] = [bg]
        var UAMpredBGs: [Double] = [bg]
        var ZTpredBGs: [Double] = [bg]

        var enableSMB = Self.enableSMB(
            profile: profile,
            microBolusAllowed: microBolusAllowed,
            meal: mealData,
            targetBg: targetBg,
            bg: bg
        )
        let enableUAM = profile.enableUAM

        var ci = round(minDelta - bgi, 1)
        let uci = round(minDelta - bgi, 1)
        let csf = sens / carbRatio
        let maxCarbAbsorptionRate = 30.0
        let maxCI = round(maxCarbAbsorptionRate * csf * 5 / 60, 1)
        if ci > maxCI { ci = maxCI }
        var remainingCATimeMin = 3.0
        remainingCATimeMin = remainingCATimeMin / sensitivityRatio
        let assumedCarbAbsorptionRate = 20.0
        var remainingCATime = remainingCATimeMin
        if mealData.carbs != 0.0 {
            remainingCATimeMin = max(remainingCATimeMin, mealData.mealCOB / assumedCarbAbsorptionRate)
            let lastCarbAge = Double(round(Double(systemTime - mealData.lastCarbTime) / 60000.0))
            remainingCATime = remainingCATimeMin + 1.5 * lastCarbAge / 60
            remainingCATime = round(remainingCATime, 1)
        }

        let totalCI = max(0.0, ci / 5 * 60 * remainingCATime / 2)
        let totalCA = totalCI / csf
        let remainingCarbsCap = min(90, profile.remainingCarbsCap)
        var remainingCarbs = max(0.0, mealData.mealCOB - totalCA)
        remainingCarbs = min(Double(remainingCarbsCap), remainingCarbs)
        let remainingCIpeak = remainingCarbs * csf * 5 / 60 / (remainingCATime / 2)

        let slopeFromMaxDeviation = round(mealData.slopeFromMaxDeviation, 2)
        let slopeFromMinDeviation = round(mealData.slopeFromMinDeviation, 2)
        let slopeFromDeviations = min(slopeFromMaxDeviation, -slopeFromMinDeviation / 3)

        let aci = 10
        let cid: Double
        if ci == 0.0 {
            cid = 0.0
        } else {
            cid = min(remainingCATime * 60 / 5 / 2, max(0.0, mealData.mealCOB * csf / ci))
        }
        let acid = max(0.0, mealData.mealCOB * csf / Double(aci))

        var minIOBPredBG = 999.0
        var minCOBPredBG = 999.0
        var minUAMPredBG = 999.0
        var minGuardBG: Double
        var minCOBGuardBG = 999.0
        var minUAMGuardBG = 999.0
        var minIOBGuardBG = 999.0
        var minZTGuardBG = 999.0
        var minPredBG: Double
        var avgPredBG: Double
        var IOBpredBG: Double = eventualBG
        var maxIOBPredBG = bg
        var maxCOBPredBG = bg
        let lastIOBpredBG: Double
        var lastCOBpredBG: Double?
        var lastUAMpredBG: Double?
        var UAMpredBG: Double?
        var COBpredBG: Double?

        // Trio addition: lowest of each guard curve over the next 45 minutes (9 ticks)
        var nearCOBGuardBG = 999.0
        var nearUAMGuardBG = 999.0
        var nearIOBGuardBG = 999.0
        let nearTicks = ObservedInsulinEffect.windowMinutes / 5

        let tdd = profile.TDD
        let divisor = Double(profile.insulinDivisor)
        for (tickIndex, iobTick) in iobArray.enumerated() {
            let predBGI = round(-iobTick.activity * sens * 5, 2) * insulinScale
            let IOBpredBGI = dynIsfMode
                ? round(
                    -iobTick.activity * (1800 / (tdd * log((max(IOBpredBGs[IOBpredBGs.count - 1], 39.0) / divisor) + 1))) * 5,
                    2
                ) * insulinScale
                : predBGI
            let zt = iobTick.iobWithZeroTemp ?? AAPSIobTotal.ZeroTemp()
            let predZTBGI = (
                dynIsfMode
                    ? round(-zt.activity * (1800 / (tdd * log((max(ZTpredBGs[ZTpredBGs.count - 1], 39.0) / divisor) + 1))) * 5, 2)
                    : round(-zt.activity * sens * 5, 2)
            ) * insulinScale
            let predUAMBGI = dynIsfMode
                ? round(
                    -iobTick.activity * (1800 / (tdd * log((max(UAMpredBGs[UAMpredBGs.count - 1], 39.0) / divisor) + 1))) * 5,
                    2
                ) * insulinScale
                : predBGI
            let predDev = ci * (1 - min(1.0, Double(IOBpredBGs.count) / (60.0 / 5.0)))
            IOBpredBG = IOBpredBGs[IOBpredBGs.count - 1] + IOBpredBGI + predDev
            let ZTpredBG = ZTpredBGs[ZTpredBGs.count - 1] + predZTBGI
            let predCI = max(0.0, max(0.0, ci) * (1 - Double(COBpredBGs.count) / max(cid * 2, 1.0)))
            let predACI = max(0.0, Double(max(0, aci)) * (1 - Double(COBpredBGs.count) / max(acid * 2, 1.0)))
            let intervals = min(Double(COBpredBGs.count), (remainingCATime * 12) - Double(COBpredBGs.count))
            let remainingCI = max(0.0, intervals / (remainingCATime / 2 * 12) * remainingCIpeak)
            let cobPred = COBpredBGs[COBpredBGs.count - 1] + predBGI + min(0.0, predDev) + predCI + remainingCI
            COBpredBG = cobPred
            let aCOBpredBG = aCOBpredBGs[aCOBpredBGs.count - 1] + predBGI + min(0.0, predDev) + predACI
            let predUCIslope = max(0.0, uci + (Double(UAMpredBGs.count) * slopeFromDeviations))
            let predUCImax = max(0.0, uci * (1 - Double(UAMpredBGs.count) / max(3.0 * 60 / 5, 1.0)))
            let predUCI = min(predUCIslope, predUCImax)
            let uamPred = UAMpredBGs[UAMpredBGs.count - 1] + predUAMBGI + min(0.0, predDev) + predUCI
            UAMpredBG = uamPred
            if IOBpredBGs.count < 48 { IOBpredBGs.append(IOBpredBG) }
            if COBpredBGs.count < 48 { COBpredBGs.append(cobPred) }
            if aCOBpredBGs.count < 48 { aCOBpredBGs.append(aCOBpredBG) }
            if UAMpredBGs.count < 48 { UAMpredBGs.append(uamPred) }
            if ZTpredBGs.count < 48 { ZTpredBGs.append(ZTpredBG) }
            if cobPred < minCOBGuardBG { minCOBGuardBG = Double(round(cobPred)) }
            if uamPred < minUAMGuardBG { minUAMGuardBG = Double(round(uamPred)) }
            if IOBpredBG < minIOBGuardBG { minIOBGuardBG = IOBpredBG }
            if ZTpredBG < minZTGuardBG { minZTGuardBG = round(ZTpredBG, 0) }
            if tickIndex < nearTicks {
                nearCOBGuardBG = min(nearCOBGuardBG, cobPred)
                nearUAMGuardBG = min(nearUAMGuardBG, uamPred)
                nearIOBGuardBG = min(nearIOBGuardBG, IOBpredBG)
            }

            let insulinPeakTime = 90.0
            let insulinPeak5m = (insulinPeakTime / 60.0) * 12.0
            if Double(IOBpredBGs.count) > insulinPeak5m, IOBpredBG < minIOBPredBG { minIOBPredBG = round(IOBpredBG, 0) }
            if IOBpredBG > maxIOBPredBG { maxIOBPredBG = IOBpredBG }
            if cid != 0.0 || remainingCIpeak > 0, Double(COBpredBGs.count) > insulinPeak5m, cobPred < minCOBPredBG {
                minCOBPredBG = round(cobPred, 0)
            }
            if cid != 0.0 || remainingCIpeak > 0, cobPred > maxIOBPredBG { maxCOBPredBG = cobPred }
            if enableUAM, UAMpredBGs.count > 12, uamPred < minUAMPredBG { minUAMPredBG = round(uamPred, 0) }
        }

        func trimTrailingFlat(_ values: inout [Double], downTo stop: Int) {
            var i = values.count - 1
            while i >= stop {
                if values[i - 1] != values[i] { break }
                values.removeLast()
                i -= 1
            }
        }

        IOBpredBGs = IOBpredBGs.map { round(min(401.0, max(39.0, $0)), 0) }
        trimTrailingFlat(&IOBpredBGs, downTo: 13)
        rT.predIOB = IOBpredBGs.map { Int($0) }
        lastIOBpredBG = Double(round(IOBpredBGs[IOBpredBGs.count - 1]))
        ZTpredBGs = ZTpredBGs.map { round(min(401.0, max(39.0, $0)), 0) }
        do {
            var i = ZTpredBGs.count - 1
            while i >= 7 {
                if ZTpredBGs[i - 1] >= ZTpredBGs[i] || ZTpredBGs[i] <= targetBg { break }
                ZTpredBGs.removeLast()
                i -= 1
            }
        }
        rT.predZT = ZTpredBGs.map { Int($0) }
        if mealData.mealCOB > 0 {
            aCOBpredBGs = aCOBpredBGs.map { round(min(401.0, max(39.0, $0)), 0) }
            trimTrailingFlat(&aCOBpredBGs, downTo: 13)
        }
        if mealData.mealCOB > 0, ci > 0 || remainingCIpeak > 0 {
            COBpredBGs = COBpredBGs.map { round(min(401.0, max(39.0, $0)), 0) }
            trimTrailingFlat(&COBpredBGs, downTo: 13)
            rT.predCOB = COBpredBGs.map { Int($0) }
            lastCOBpredBG = COBpredBGs[COBpredBGs.count - 1]
            eventualBG = max(eventualBG, round(COBpredBGs[COBpredBGs.count - 1], 0))
        }
        if ci > 0 || remainingCIpeak > 0 {
            if enableUAM {
                UAMpredBGs = UAMpredBGs.map { round(min(401.0, max(39.0, $0)), 0) }
                trimTrailingFlat(&UAMpredBGs, downTo: 13)
                rT.predUAM = UAMpredBGs.map { Int($0) }
                lastUAMpredBG = UAMpredBGs[UAMpredBGs.count - 1]
                eventualBG = max(eventualBG, round(UAMpredBGs[UAMpredBGs.count - 1], 0))
            }
            rT.eventualBG = eventualBG
        }

        minIOBPredBG = max(39.0, minIOBPredBG)
        minCOBPredBG = max(39.0, minCOBPredBG)
        minUAMPredBG = max(39.0, minUAMPredBG)
        minPredBG = round(minIOBPredBG, 0)

        let fSensBG = min(minPredBG, bg)

        var futureSens = 0.0
        if dynIsfMode {
            if bg > targetBg, glucoseStatus.delta < 3, glucoseStatus.delta > -3, glucoseStatus.shortAvgDelta > -3,
               glucoseStatus.shortAvgDelta < 3, eventualBG > targetBg, eventualBG < bg
            {
                futureSens = 1800 / (log((((fSensBG * 0.5) + (bg * 0.5)) / divisor) + 1) * tdd)
                futureSens = round(futureSens, 1)
                rT.reason += "Dosing sensitivity: \(F.kt(futureSens)) using eventual BG;"
            } else if glucoseStatus.delta > 0 && eventualBG > targetBg || eventualBG > bg {
                futureSens = 1800 / (log((bg / divisor) + 1) * tdd)
                futureSens = round(futureSens, 1)
                rT.reason += "Dosing sensitivity: \(F.kt(futureSens)) using current BG;"
            } else {
                futureSens = 1800 / (log((fSensBG / divisor) + 1) * tdd)
                futureSens = round(futureSens, 1)
                rT.reason += "Dosing sensitivity: \(F.kt(futureSens)) using eventual BG;"
            }
        }

        let fractionCarbsLeft = mealData.mealCOB / mealData.carbs
        if minUAMPredBG < 999, minCOBPredBG < 999 {
            avgPredBG = round((1 - fractionCarbsLeft) * (UAMpredBG ?? 0) + fractionCarbsLeft * (COBpredBG ?? 0), 0)
        } else if minCOBPredBG < 999 {
            avgPredBG = round((IOBpredBG + (COBpredBG ?? 0)) / 2.0, 0)
        } else if minUAMPredBG < 999 {
            avgPredBG = round((IOBpredBG + (UAMpredBG ?? 0)) / 2.0, 0)
        } else {
            avgPredBG = round(IOBpredBG, 0)
        }
        if minZTGuardBG > avgPredBG { avgPredBG = minZTGuardBG }

        if cid > 0.0 || remainingCIpeak > 0 {
            if enableUAM {
                minGuardBG = fractionCarbsLeft * minCOBGuardBG + (1 - fractionCarbsLeft) * minUAMGuardBG
            } else {
                minGuardBG = minCOBGuardBG
            }
        } else if enableUAM {
            minGuardBG = minUAMGuardBG
        } else {
            minGuardBG = minIOBGuardBG
        }
        minGuardBG = round(minGuardBG, 0)

        // Trio addition: the same blend over the next 45 minutes only, for the observed-effect gate
        var nearGuardBG: Double
        if cid > 0.0 || remainingCIpeak > 0 {
            nearGuardBG = enableUAM
                ? fractionCarbsLeft * nearCOBGuardBG + (1 - fractionCarbsLeft) * nearUAMGuardBG
                : nearCOBGuardBG
        } else if enableUAM {
            nearGuardBG = nearUAMGuardBG
        } else {
            nearGuardBG = nearIOBGuardBG
        }
        nearGuardBG = round(nearGuardBG, 0)

        // Trio addition: the guard alone may count entered carbs that are still to come.
        var guardBG = minGuardBG
        if guardUpcomingCarbs > 0 {
            let withUpcoming = upcomingCarbsGuardBG(
                upcomingCarbs: guardUpcomingCarbs,
                mealData: mealData,
                systemTime: systemTime,
                sensitivityRatio: sensitivityRatio,
                ci: ci,
                csf: csf,
                sens: sens,
                profile: profile,
                iobArray: iobArray,
                bg: bg,
                enableUAM: enableUAM,
                minUAMGuardBG: minUAMGuardBG,
                fallback: minGuardBG,
                insulinScale: insulinScale
            )
            guardBG = max(minGuardBG, withUpcoming)
        }
        // it only ever changes the decision by stopping a block that BG itself does not call for:
        // BG well above the threshold and not falling. It can re-allow SMBs only; the zero-temp
        // suspend below still follows the unmodified minGuardBG.
        let guardReleased = minGuardBG < threshold && guardBG >= threshold && bg >= max(threshold, 150) && minDelta >= 0
        let effectiveGuardBG = guardReleased ? guardBG : minGuardBG

        var minZTUAMPredBG = minUAMPredBG
        if minZTGuardBG < threshold {
            minZTUAMPredBG = (minUAMPredBG + minZTGuardBG) / 2.0
        } else if minZTGuardBG < targetBg {
            let blendPct = (minZTGuardBG - threshold) / (targetBg - threshold)
            let blendedMinZTGuardBG = minUAMPredBG * blendPct + minZTGuardBG * (1 - blendPct)
            minZTUAMPredBG = (minUAMPredBG + blendedMinZTGuardBG) / 2.0
        } else if minZTGuardBG > minUAMPredBG {
            minZTUAMPredBG = (minUAMPredBG + minZTGuardBG) / 2.0
        }
        minZTUAMPredBG = round(minZTUAMPredBG, 0)
        if mealData.carbs != 0.0 {
            if !enableUAM, minCOBPredBG < 999 {
                minPredBG = round(max(minIOBPredBG, minCOBPredBG), 0)
            } else if minCOBPredBG < 999 {
                let blendedMinPredBG = fractionCarbsLeft * minCOBPredBG + (1 - fractionCarbsLeft) * minZTUAMPredBG
                minPredBG = round(max(minIOBPredBG, max(minCOBPredBG, blendedMinPredBG)), 0)
            } else if enableUAM {
                minPredBG = minZTUAMPredBG
            } else {
                minPredBG = minGuardBG
            }
        } else if enableUAM {
            minPredBG = round(max(minIOBPredBG, minZTUAMPredBG), 0)
        }
        minPredBG = min(minPredBG, avgPredBG)
        if maxCOBPredBG > bg { minPredBG = min(minPredBG, maxCOBPredBG) }

        rT.COB = mealData.mealCOB
        rT.IOB = iobData.iob
        rT
            .reason +=
            "COB: \(F.withoutZeros(round(mealData.mealCOB, 1))), Dev: \(F.convertBg(Double(deviation))), BGI: \(F.convertBg(bgi)), ISF: \(F.convertBg(sens)), CR: \(F.withoutZeros(round(carbRatio, 2))), Target: \(F.convertBg(targetBg)), minPredBG \(F.convertBg(minPredBG)), minGuardBG \(F.convertBg(minGuardBG)), IOBpredBG \(F.convertBg(lastIOBpredBG))"
        if let lastCOBpredBG { rT.reason += ", COBpredBG " + F.convertBg(lastCOBpredBG) }
        if let lastUAMpredBG { rT.reason += ", UAMpredBG " + F.convertBg(lastUAMpredBG) }
        rT.reason += "; "
        if insulinScale != 1 {
            rT.reason += "observed insulin effect x\(F.withoutZeros(round(insulinScale, 2))); "
        }
        if guardReleased {
            rT.reason +=
                "upcoming fat/protein \(F.withoutZeros(round(guardUpcomingCarbs, 1)))g: guard minGuardBG \(F.convertBg(guardBG)), not blocked; "
        }

        var carbsReqBG = naiveEventualBG
        if carbsReqBG < 40 { carbsReqBG = min(minGuardBG, carbsReqBG) }
        var bgUndershoot: Double = threshold - carbsReqBG
        var minutesAboveMinBG = 240
        var minutesAboveThreshold = 240
        if mealData.mealCOB > 0, ci > 0 || remainingCIpeak > 0 {
            for i in COBpredBGs.indices where COBpredBGs[i] < minBg { minutesAboveMinBG = 5 * i
                break }
            for i in COBpredBGs.indices where COBpredBGs[i] < threshold { minutesAboveThreshold = 5 * i
                break }
        } else {
            for i in IOBpredBGs.indices where IOBpredBGs[i] < minBg { minutesAboveMinBG = 5 * i
                break }
            for i in IOBpredBGs.indices where IOBpredBGs[i] < threshold { minutesAboveThreshold = 5 * i
                break }
        }

        _ = minutesAboveMinBG // AAPS only logs this one
        if enableSMB, effectiveGuardBG < threshold { enableSMB = false }
        if maxDelta > 0.20 * bg {
            rT.reason += "maxDelta " + F.convertBg(maxDelta) + " > 20% of BG " + F.convertBg(bg) + ": SMB disabled; "
            enableSMB = false
        }

        let zeroTempDuration = minutesAboveThreshold
        let zeroTempEffectDouble = profile.current_basal * sens * Double(zeroTempDuration) / 60
        let COBforCarbsReq = max(0.0, mealData.mealCOB - 0.25 * mealData.carbs)
        let carbsReq = round((bgUndershoot - zeroTempEffectDouble) / csf - COBforCarbsReq)
        if carbsReq >= profile.carbsReqThreshold, minutesAboveThreshold <= 45 {
            rT.carbsReq = carbsReq
            rT.carbsReqWithin = minutesAboveThreshold
            rT.reason += "\(carbsReq) add'l carbs req w/in \(minutesAboveThreshold)m; "
        }

        rT.trace = AAPSDetermineBasalTrace(
            sens: sens, carbRatio: carbRatio, bgi: bgi, deviation: deviation, naiveEventualBG: naiveEventualBG,
            eventualBG: eventualBG, minPredBG: minPredBG, minGuardBG: minGuardBG, minIOBPredBG: minIOBPredBG,
            futureSens: futureSens, targetBG: targetBg, minBG: minBg, maxBG: maxBg, threshold: threshold,
            basal: basal, expectedDelta: expectedDelta, minDelta: minDelta, enableSMB: enableSMB,
            tierMultiplier: tierMultiplier,
            guardBG: guardBG,
            guardReleasedByUpcomingCarbs: guardReleased,
            nearGuardBG: nearGuardBG,
            observedInsulinEffect: insulinScale
        )

        if bg < threshold, iobData.iob < -profile.current_basal * 20 / 60, minDelta > 0, minDelta > expectedDelta {
            rT.reason += "IOB \(F.kt(iobData.iob)) < \(F.kt(round(-profile.current_basal * 20 / 60, 2)))"
            rT.reason += " and minDelta \(F.convertBg(minDelta)) > expectedDelta \(F.convertBg(expectedDelta)); "
        } else if bg < threshold || minGuardBG < threshold {
            rT.reason += "minGuardBG \(F.convertBg(minGuardBG)) < \(F.convertBg(threshold))"
            bgUndershoot = targetBg - minGuardBG
            let worstCaseInsulinReq = bgUndershoot / sens
            var durationReq = round(60 * worstCaseInsulinReq / profile.current_basal)
            durationReq = round(Double(durationReq) / 30.0) * 30
            durationReq = min(120, max(30, durationReq))
            return setTempBasal(0.0, durationReq, profile, rT, currenttemp)
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let minutes = calendar.component(.minute, from: Date(timeIntervalSince1970: Double(deliverAt) / 1000.0))
        if profile.skip_neutral_temps, minutes >= 55 {
            rT.reason += "; Canceling temp at " + "\(minutes)" + "m past the hour. "
            return setTempBasal(0.0, 0, profile, rT, currenttemp)
        }

        if eventualBG < minBg {
            rT.reason += "Eventual BG \(F.convertBg(eventualBG)) < \(F.convertBg(minBg))"
            if minDelta > expectedDelta, minDelta > 0, carbsReq == 0 {
                if naiveEventualBG < 40 {
                    rT.reason += ", naive_eventualBG < 40. "
                    return setTempBasal(0.0, 30, profile, rT, currenttemp)
                }
                if glucoseStatus.delta > minDelta {
                    rT.reason += ", but Delta \(F.convertBg(Double(tick) ?? 0)) > expectedDelta \(F.convertBg(expectedDelta))"
                } else {
                    rT.reason += ", but Min. Delta \(F.toFixed2(minDelta)) > Exp. Delta \(F.convertBg(expectedDelta))"
                }
                if currenttemp.duration > 15, basal == currenttemp.rate {
                    rT.reason += ", temp " + F.kt(currenttemp.rate) + " ~ req " + F.withoutZeros(round(basal, 2)) + "U/hr. "
                    return rT
                } else {
                    rT.reason += "; setting current basal of \(F.kt(round(basal, 2))) as temp. "
                    return setTempBasal(basal, 30, profile, rT, currenttemp)
                }
            }

            var insulinReq = dynIsfMode
                ? 2 * min(0.0, (eventualBG - targetBg) / futureSens)
                : 2 * min(0.0, (eventualBG - targetBg) / sens)
            insulinReq = round(insulinReq, 2)
            var naiveInsulinReq = min(0.0, (naiveEventualBG - targetBg) / sens)
            naiveInsulinReq = round(naiveInsulinReq, 2)
            if minDelta < 0, minDelta > expectedDelta {
                let newinsulinReq = round(insulinReq * (minDelta / expectedDelta), 2)
                insulinReq = newinsulinReq
            }
            let rate = basal + (2 * insulinReq)
            let insulinScheduled = Double(currenttemp.duration) * (currenttemp.rate - basal) / 60
            let minInsulinReq = min(insulinReq, naiveInsulinReq)
            if insulinScheduled < minInsulinReq - basal * 0.3 {
                rT.reason += ", \(currenttemp.duration)m@\(F.toFixed2(currenttemp.rate)) is a lot less than needed. "
                return setTempBasal(rate, 30, profile, rT, currenttemp)
            }
            if currenttemp.duration > 5, rate >= currenttemp.rate * 0.8 {
                rT.reason += ", temp \(F.kt(currenttemp.rate)) ~< req \(F.kt(round(rate, 2)))U/hr. "
                return rT
            } else {
                if rate <= 0 {
                    bgUndershoot = targetBg - naiveEventualBG
                    let worstCaseInsulinReq = bgUndershoot / sens
                    var durationReq = round(60 * worstCaseInsulinReq / profile.current_basal)
                    if durationReq < 0 {
                        durationReq = 0
                    } else {
                        durationReq = round(Double(durationReq) / 30.0) * 30
                        durationReq = min(120, max(0, durationReq))
                    }
                    if durationReq > 0 {
                        rT.reason += ", setting \(durationReq)m zero temp. "
                        return setTempBasal(rate, durationReq, profile, rT, currenttemp)
                    }
                } else {
                    rT.reason += ", setting \(F.kt(round(rate, 2)))U/hr. "
                }
                return setTempBasal(rate, 30, profile, rT, currenttemp)
            }
        }

        if minDelta < expectedDelta {
            if !(microBolusAllowed && enableSMB) {
                if glucoseStatus.delta < minDelta {
                    rT
                        .reason +=
                        "Eventual BG \(F.convertBg(eventualBG)) > \(F.convertBg(minBg)) but Delta \(F.convertBg(Double(tick) ?? 0)) < Exp. Delta \(F.convertBg(expectedDelta))"
                } else {
                    rT
                        .reason +=
                        "Eventual BG \(F.convertBg(eventualBG)) > \(F.convertBg(minBg)) but Min. Delta \(F.toFixed2(minDelta)) < Exp. Delta \(F.convertBg(expectedDelta))"
                }
                if currenttemp.duration > 15, basal == currenttemp.rate {
                    rT.reason += ", temp " + F.kt(currenttemp.rate) + " ~ req " + F.withoutZeros(round(basal, 2)) + "U/hr. "
                    return rT
                } else {
                    rT.reason += "; setting current basal of \(F.kt(round(basal, 2))) as temp. "
                    return setTempBasal(basal, 30, profile, rT, currenttemp)
                }
            }
        }
        if min(eventualBG, minPredBG) < maxBg {
            if !(microBolusAllowed && enableSMB) {
                rT.reason += "\(F.convertBg(eventualBG))-\(F.convertBg(minPredBG)) in range: no temp required"
                if currenttemp.duration > 15, basal == currenttemp.rate {
                    rT.reason += ", temp \(F.kt(currenttemp.rate)) ~ req \(F.withoutZeros(round(basal, 2)))U/hr. "
                    return rT
                } else {
                    rT.reason += "; setting current basal of \(F.kt(round(basal, 2))) as temp. "
                    return setTempBasal(basal, 30, profile, rT, currenttemp)
                }
            }
        }

        if eventualBG >= maxBg {
            rT.reason += "Eventual BG " + F.convertBg(eventualBG) + " >= " + F.convertBg(maxBg) + ", "
        }
        if iobData.iob > maxIob {
            rT.reason += "IOB \(F.kt(round(iobData.iob, 2))) > max_iob \(F.kt(maxIob))"
            if currenttemp.duration > 15, basal == currenttemp.rate {
                rT.reason += ", temp \(F.kt(currenttemp.rate)) ~ req \(F.withoutZeros(round(basal, 2)))U/hr. "
                return rT
            } else {
                rT.reason += "; setting current basal of \(F.kt(round(basal, 2))) as temp. "
                return setTempBasal(basal, 30, profile, rT, currenttemp)
            }
        } else {
            var insulinReq = dynIsfMode
                ? round((min(minPredBG, eventualBG) - targetBg) / futureSens, 2)
                : round((min(minPredBG, eventualBG) - targetBg) / sens, 2)
            if insulinReq > maxIob - iobData.iob {
                rT.reason += "max_iob \(F.kt(maxIob)), "
                insulinReq = maxIob - iobData.iob
            }
            var rate = basal + (2 * insulinReq)
            insulinReq = round(insulinReq, 3)
            rT.insulinReq = insulinReq
            if microBolusAllowed, enableSMB, bg > threshold {
                let mealInsulinReq = round(mealData.mealCOB / carbRatio, 3)
                let maxBolus: Double
                if iobData.iob > mealInsulinReq, iobData.iob > 0 {
                    maxBolus = round(profile.current_basal * Double(profile.maxUAMSMBBasalMinutes) / 60, 1)
                } else {
                    maxBolus = round(profile.current_basal * Double(profile.maxSMBBasalMinutes) / 60, 1)
                }
                let roundSMBTo = 1 / profile.bolus_increment
                let microBolus = (min(insulinReq / 2, maxBolus) * roundSMBTo).rounded(.down) / roundSMBTo
                rT.trace.maxBolus = maxBolus
                rT.trace.microBolus = microBolus
                let smbTarget = targetBg
                let worstCaseInsulinReq = (smbTarget - (naiveEventualBG + minIOBPredBG) / 2.0) / sens
                var durationReq = round(60 * worstCaseInsulinReq / profile.current_basal)
                if insulinReq > 0, microBolus < profile.bolus_increment { durationReq = 0 }
                var smbLowTempReq = 0.0
                if durationReq <= 0 {
                    durationReq = 0
                } else if durationReq >= 30 {
                    durationReq = round(Double(durationReq) / 30.0) * 30
                    durationReq = min(60, max(0, durationReq))
                } else {
                    smbLowTempReq = round(basal * Double(durationReq) / 30.0, 2)
                    durationReq = 30
                }
                rT.reason += " insulinReq \(F.kt(insulinReq))"
                if microBolus >= maxBolus { rT.reason += "; maxBolus \(F.kt(maxBolus))" }
                if durationReq > 0 { rT.reason += "; setting \(durationReq)m low temp of \(F.kt(smbLowTempReq))U/h" }
                rT.reason += ". "

                let lastBolusAge = Double(systemTime - iobData.lastBolusTime) / 1000.0
                let SMBInterval = Double(min(10, max(1, profile.SMBInterval))) * 60.0
                if lastBolusAge > SMBInterval - 6.0 {
                    if microBolus > 0 {
                        rT.units = microBolus
                        rT.reason += "Microbolusing \(F.kt(microBolus))U. "
                    }
                } else {
                    let nextBolusMins = (SMBInterval - lastBolusAge) / 60.0
                    let nextBolusSeconds = (SMBInterval - lastBolusAge).truncatingRemainder(dividingBy: 60)
                    let waitingSeconds = round(nextBolusSeconds, 0).truncatingRemainder(dividingBy: 60)
                    let waitingMins = round(nextBolusMins - waitingSeconds / 60.0, 0)
                    rT.reason += "Waiting \(F.withoutZeros(waitingMins))m \(F.withoutZeros(waitingSeconds))s to microbolus again."
                }
                if durationReq > 0 {
                    rT.rate = smbLowTempReq
                    rT.duration = durationReq
                    return rT
                }
            }

            let maxSafe = maxSafeBasal(profile)
            if rate > maxSafe {
                rT.reason += "adj. req. rate: \(F.kt(round(rate, 2))) to maxSafeBasal: \(F.withoutZeros(maxSafe)), "
                rate = maxSafe
            }
            let insulinScheduled = Double(currenttemp.duration) * (currenttemp.rate - basal) / 60
            if insulinScheduled >= insulinReq * 2 {
                rT
                    .reason +=
                    "\(currenttemp.duration)m@\(F.toFixed2(currenttemp.rate)) > 2 * insulinReq. Setting temp basal of \(F.kt(round(rate, 2)))U/hr. "
                return setTempBasal(rate, 30, profile, rT, currenttemp)
            }
            if currenttemp.duration == 0 {
                rT.reason += "no temp, setting " + F.withoutZeros(round(rate, 2)) + "U/hr. "
                return setTempBasal(rate, 30, profile, rT, currenttemp)
            }
            if currenttemp.duration > 5, rate <= currenttemp.rate {
                rT.reason += "temp \(F.toFixed2(currenttemp.rate)) >~ req \(F.withoutZeros(round(rate, 2)))U/hr. "
                return rT
            }
            rT.reason += "temp \(F.toFixed2(currenttemp.rate)) < \(F.withoutZeros(round(rate, 2)))U/hr. "
            return setTempBasal(rate, 30, profile, rT, currenttemp)
        }
    }

    /// minGuardBG as above, with `upcomingCarbs` grams added to COB and to the carbs total, for the
    /// low-glucose guard only. Mirrors the remaining-carbs setup, the COB prediction and the COB/UAM
    /// guard blend of `determineBasal`. When the carbs make no COB prediction, returns `fallback`.
    /// `insulinScale` is the observed-insulin-effect factor of the main forecast.
    // swiftlint:disable:next function_parameter_count
    static func upcomingCarbsGuardBG(
        upcomingCarbs: Double,
        mealData: AAPSMealData,
        systemTime: Int64,
        sensitivityRatio: Double,
        ci: Double,
        csf: Double,
        sens: Double,
        profile: AAPSOapsProfile,
        iobArray: [AAPSIobTotal],
        bg: Double,
        enableUAM: Bool,
        minUAMGuardBG: Double,
        fallback: Double,
        insulinScale: Double = 1
    ) -> Double {
        let mealCOB = mealData.mealCOB + upcomingCarbs
        let carbs = mealData.carbs + upcomingCarbs
        guard carbs > 0 else { return fallback }

        var remainingCATimeMin = 3.0 / sensitivityRatio
        remainingCATimeMin = max(remainingCATimeMin, mealCOB / 20.0)
        // no past carbs means no last carb time: count the upcoming carbs as entered now
        let lastCarbAge = mealData.carbs != 0.0 ? Double(round(Double(systemTime - mealData.lastCarbTime) / 60000.0)) : 0
        let remainingCATime = round(remainingCATimeMin + 1.5 * lastCarbAge / 60, 1)

        let totalCI = max(0.0, ci / 5 * 60 * remainingCATime / 2)
        let totalCA = totalCI / csf
        let remainingCarbsCap = min(90, profile.remainingCarbsCap)
        let remainingCarbs = min(Double(remainingCarbsCap), max(0.0, mealCOB - totalCA))
        let remainingCIpeak = remainingCarbs * csf * 5 / 60 / (remainingCATime / 2)
        let cid = ci == 0.0 ? 0.0 : min(remainingCATime * 60 / 5 / 2, max(0.0, mealCOB * csf / ci))
        guard cid > 0.0 || remainingCIpeak > 0 else { return fallback }

        var COBpredBGs: [Double] = [bg]
        var minCOBGuardBG = 999.0
        for iobTick in iobArray {
            let predBGI = round(-iobTick.activity * sens * 5, 2) * insulinScale
            let predDev = ci * (1 - min(1.0, Double(COBpredBGs.count) / (60.0 / 5.0)))
            let predCI = max(0.0, max(0.0, ci) * (1 - Double(COBpredBGs.count) / max(cid * 2, 1.0)))
            let intervals = min(Double(COBpredBGs.count), (remainingCATime * 12) - Double(COBpredBGs.count))
            let remainingCI = max(0.0, intervals / (remainingCATime / 2 * 12) * remainingCIpeak)
            let cobPred = COBpredBGs[COBpredBGs.count - 1] + predBGI + min(0.0, predDev) + predCI + remainingCI
            if COBpredBGs.count < 48 { COBpredBGs.append(cobPred) }
            if cobPred < minCOBGuardBG { minCOBGuardBG = Double(round(cobPred)) }
        }

        let fractionCarbsLeft = mealCOB / carbs
        let guardBG = enableUAM
            ? fractionCarbsLeft * minCOBGuardBG + (1 - fractionCarbsLeft) * minUAMGuardBG
            : minCOBGuardBG
        return round(guardBG, 0)
    }
}
