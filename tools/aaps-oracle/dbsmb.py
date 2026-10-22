"""Python port of AAPS fork DetermineBasalSMB.determine_basal at release 42bb385ff4.
Faithful line by line for the dosing path, used to replay logged APSResult inputs with
the ISF tier on (as logged) and off (counterfactual)."""
import math


def jround(v, digits=None):
    if digits is None:
        return math.floor(v + 0.5)
    if isinstance(v, float) and math.isnan(v):
        return v
    s = 10.0 ** digits
    return math.floor(v * s + 0.5) / s


def tier_mult(g, tiers):
    for lo, hi, m in tiers:
        if lo <= g < hi:
            return m
    return 1.0


def carb_tier(cr, g, tiers):
    if g < 140.0:
        return cr
    m = tier_mult(g, tiers)
    if m <= 0 or m >= 1:
        return cr
    agg = 1.0 / m
    d = (agg - 1.0) / 2.0 + 1.0
    d = min(d, 1.3)
    return cr / d


def determine_basal(gs, ct, iobArray, p, ad, meal, microBolusAllowed, currentTime, flatBGs, dyn,
                    tiersEnabled=False, tiers=None, onDynamic=False, autosensMin=0.7, sensOverride=None):
    out = {}
    basal = p['current_basal']
    profile_current_basal = basal
    bg = gs['glucose']
    minAgo = jround((currentTime - gs['date']) / 60.0 / 1000.0, 1)
    noise = gs.get('noise', 0.0)
    if bg <= 10 or bg == 38.0 or noise >= 3 or minAgo > 12 or minAgo < -5 or (bg > 60 and flatBGs):
        return {'error': 'bg invalid'}
    max_iob = p['max_iob']
    target_bg = (p['min_bg'] + p['max_bg']) / 2
    min_bg = p['min_bg']
    max_bg = p['max_bg']
    normalTarget = 100
    htrs = p['exercise_mode'] or p['high_temptarget_raises_sensitivity']
    if (htrs and p['temptargetSet'] and target_bg > normalTarget) or (p['low_temptarget_lowers_sensitivity'] and p['temptargetSet'] and target_bg < normalTarget):
        c = float(p['half_basal_exercise_target'] - normalTarget)
        sensitivityRatio = c / (c + target_bg - normalTarget)
        sensitivityRatio = min(sensitivityRatio, p['autosens_max'])
        sensitivityRatio = jround(sensitivityRatio, 2)
    else:
        sensitivityRatio = ad['ratio']
    basal = p['current_basal'] * sensitivityRatio
    if not p['temptargetSet']:
        if (p['sensitivity_raises_target'] and ad['ratio'] < 1) or (p['resistance_lowers_target'] and ad['ratio'] > 1):
            min_bg = jround((min_bg - 60) / ad['ratio'], 0) + 60
            max_bg = jround((max_bg - 60) / ad['ratio'], 0) + 60
            ntb = jround((target_bg - 60) / ad['ratio'], 0) + 60
            ntb = max(80.0, ntb)
            target_bg = ntb
    iob_data = iobArray[0]
    delta = gs['delta']
    minDelta = min(gs['delta'], gs['shortAvgDelta'])
    minAvgDelta = min(gs['shortAvgDelta'], gs['longAvgDelta'])
    maxDelta = max(gs['delta'], max(gs['shortAvgDelta'], gs['longAvgDelta']))

    tier_m = 1.0
    if sensOverride is not None:
        sens = sensOverride
    elif dyn:
        if not tiersEnabled:
            sens = p['variable_sens']
        elif onDynamic:
            tier_m = tier_mult(bg, tiers)
            sens = p['variable_sens'] * tier_m
        else:
            tier_m = tier_mult(bg, tiers)
            if p['variable_sens'] <= 0 or p['sens'] <= 0:
                sens = p['variable_sens']
            else:
                tiered = p['sens'] * tier_m
                ratio = min(max(tiered / p['variable_sens'], autosensMin), p['autosens_max'])
                sens = tiered / ratio
    else:
        sens = jround(p['sens'] / sensitivityRatio, 1)
        if tiersEnabled:
            tier_m = tier_mult(bg, tiers)
            sens = sens * tier_m
    carbRatio = carb_tier(p['carb_ratio'], bg, tiers) if tiersEnabled else p['carb_ratio']
    out['sens'] = sens
    out['carbRatio'] = carbRatio

    bgi = jround(-iob_data['activity'] * sens * 5, 2)
    deviation = jround(30 / 5 * (minDelta - bgi))
    if deviation < 0:
        deviation = jround((30 / 5) * (minAvgDelta - bgi))
        if deviation < 0:
            deviation = jround((30 / 5) * (gs['longAvgDelta'] - bgi))
    if dyn:
        naive_eventualBG = jround(bg - iob_data['iob'] * sens, 0)
    else:
        if iob_data['iob'] > 0:
            naive_eventualBG = jround(bg - iob_data['iob'] * sens, 0)
        else:
            naive_eventualBG = jround(bg - iob_data['iob'] * min(sens, p['sens']), 0)
    eventualBG = naive_eventualBG + deviation
    if bg > max_bg and p['adv_target_adjustments'] and not p['temptargetSet']:
        raise NotImplementedError('adv_target_adjustments')
    expectedDelta = jround(bgi + (target_bg - eventualBG) / 24, 1)
    threshold = min_bg - 0.5 * (min_bg - 40)
    if p.get('lgsThreshold') is not None and p['lgsThreshold'] > threshold:
        threshold = float(p['lgsThreshold'])

    COBpredBGs = [bg]; aCOBpredBGs = [bg]; IOBpredBGs = [bg]; ZTpredBGs = [bg]; UAMpredBGs = [bg]
    # enable_smb
    if not microBolusAllowed:
        enableSMB = False
    elif not p['allowSMB_with_high_temptarget'] and p['temptargetSet'] and target_bg > 100:
        enableSMB = False
    elif p['enableSMB_always']:
        enableSMB = True
    elif p['enableSMB_with_COB'] and meal['mealCOB'] != 0.0:
        enableSMB = True
    elif p['enableSMB_after_carbs'] and meal['carbs'] != 0.0:
        enableSMB = True
    elif p['enableSMB_with_temptarget'] and p['temptargetSet'] and target_bg < 100:
        enableSMB = True
    else:
        enableSMB = False
    enableUAM = p['enableUAM']
    ci = jround(minDelta - bgi, 1)
    uci = jround(minDelta - bgi, 1)
    csf = sens / carbRatio
    maxCarbAbsorptionRate = 30
    maxCI = jround(maxCarbAbsorptionRate * csf * 5 / 60, 1)
    if ci > maxCI:
        ci = maxCI
    remainingCATimeMin = 3.0
    remainingCATimeMin = remainingCATimeMin / sensitivityRatio
    assumedCarbAbsorptionRate = 20
    remainingCATime = remainingCATimeMin
    if meal['carbs'] != 0.0:
        remainingCATimeMin = max(remainingCATimeMin, meal['mealCOB'] / assumedCarbAbsorptionRate)
        lastCarbAge = jround((currentTime - meal['lastCarbTime']) / 60000.0)
        remainingCATime = remainingCATimeMin + 1.5 * lastCarbAge / 60
        remainingCATime = jround(remainingCATime, 1)
    totalCI = max(0.0, ci / 5 * 60 * remainingCATime / 2)
    totalCA = totalCI / csf
    remainingCarbsCap = min(90, p['remainingCarbsCap'])
    remainingCarbs = max(0.0, meal['mealCOB'] - totalCA)
    remainingCarbs = min(float(remainingCarbsCap), remainingCarbs)
    remainingCIpeak = remainingCarbs * csf * 5 / 60 / (remainingCATime / 2)
    slopeFromMaxDeviation = jround(meal['slopeFromMaxDeviation'], 2)
    slopeFromMinDeviation = jround(meal['slopeFromMinDeviation'], 2)
    slopeFromDeviations = min(slopeFromMaxDeviation, -slopeFromMinDeviation / 3)
    aci = 10
    if ci == 0.0:
        cid = 0.0
    else:
        cid = min(remainingCATime * 60 / 5 / 2, max(0.0, meal['mealCOB'] * csf / ci))
    acid = max(0.0, meal['mealCOB'] * csf / aci)
    minIOBPredBG = minCOBPredBG = minUAMPredBG = 999.0
    minCOBGuardBG = minUAMGuardBG = minIOBGuardBG = minZTGuardBG = 999.0
    IOBpredBG = eventualBG
    maxIOBPredBG = bg
    maxCOBPredBG = bg
    UAMduration = 0.0
    UAMpredBG = None
    COBpredBG = None
    TDD = p['TDD']; idiv = p['insulinDivisor']
    for tick in iobArray:
        predBGI = jround(-tick['activity'] * sens * 5, 2)
        if dyn:
            IOBpredBGI = jround(-tick['activity'] * (1800 / (TDD * (math.log(max(IOBpredBGs[-1], 39.0) / idiv + 1)))) * 5, 2)
        else:
            IOBpredBGI = predBGI
        zt = tick['iobWithZeroTemp']
        if dyn:
            predZTBGI = jround(-zt['activity'] * (1800 / (TDD * (math.log(max(ZTpredBGs[-1], 39.0) / idiv + 1)))) * 5, 2)
            predUAMBGI = jround(-tick['activity'] * (1800 / (TDD * (math.log(max(UAMpredBGs[-1], 39.0) / idiv + 1)))) * 5, 2)
        else:
            predZTBGI = jround(-zt['activity'] * sens * 5, 2)
            predUAMBGI = predBGI
        predDev = ci * (1 - min(1.0, len(IOBpredBGs) / (60.0 / 5.0)))
        IOBpredBG = IOBpredBGs[-1] + IOBpredBGI + predDev
        ZTpredBG = ZTpredBGs[-1] + predZTBGI
        predCI = max(0.0, max(0.0, ci) * (1 - len(COBpredBGs) / max(cid * 2, 1.0)))
        predACI = max(0.0, max(0, aci) * (1 - len(COBpredBGs) / max(acid * 2, 1.0)))
        intervals = min(float(len(COBpredBGs)), (remainingCATime * 12) - len(COBpredBGs))
        remainingCI = max(0.0, intervals / (remainingCATime / 2 * 12) * remainingCIpeak)
        COBpredBG = COBpredBGs[-1] + predBGI + min(0.0, predDev) + predCI + remainingCI
        aCOBpredBG = aCOBpredBGs[-1] + predBGI + min(0.0, predDev) + predACI
        predUCIslope = max(0.0, uci + (len(UAMpredBGs) * slopeFromDeviations))
        predUCImax = max(0.0, uci * (1 - len(UAMpredBGs) / max(3.0 * 60 / 5, 1.0)))
        predUCI = min(predUCIslope, predUCImax)
        if predUCI > 0:
            UAMduration = jround((len(UAMpredBGs) + 1) * 5 / 60.0, 1)
        UAMpredBG = UAMpredBGs[-1] + predUAMBGI + min(0.0, predDev) + predUCI
        if len(IOBpredBGs) < 48: IOBpredBGs.append(IOBpredBG)
        if len(COBpredBGs) < 48: COBpredBGs.append(COBpredBG)
        if len(aCOBpredBGs) < 48: aCOBpredBGs.append(aCOBpredBG)
        if len(UAMpredBGs) < 48: UAMpredBGs.append(UAMpredBG)
        if len(ZTpredBGs) < 48: ZTpredBGs.append(ZTpredBG)
        if COBpredBG < minCOBGuardBG: minCOBGuardBG = float(jround(COBpredBG))
        if UAMpredBG < minUAMGuardBG: minUAMGuardBG = float(jround(UAMpredBG))
        if IOBpredBG < minIOBGuardBG: minIOBGuardBG = IOBpredBG
        if ZTpredBG < minZTGuardBG: minZTGuardBG = jround(ZTpredBG, 0)
        insulinPeak5m = (90 / 60.0) * 12.0
        if len(IOBpredBGs) > insulinPeak5m and IOBpredBG < minIOBPredBG: minIOBPredBG = jround(IOBpredBG, 0)
        if IOBpredBG > maxIOBPredBG: maxIOBPredBG = IOBpredBG
        if (cid != 0.0 or remainingCIpeak > 0) and len(COBpredBGs) > insulinPeak5m and COBpredBG < minCOBPredBG: minCOBPredBG = jround(COBpredBG, 0)
        if (cid != 0.0 or remainingCIpeak > 0) and COBpredBG > maxIOBPredBG: maxCOBPredBG = COBpredBG
        if enableUAM and len(UAMpredBGs) > 12 and UAMpredBG < minUAMPredBG: minUAMPredBG = jround(UAMpredBG, 0)

    IOBpredBGs = [jround(min(401.0, max(39.0, x)), 0) for x in IOBpredBGs]
    i = len(IOBpredBGs) - 1
    while i >= 13:
        if IOBpredBGs[i - 1] != IOBpredBGs[i]: break
        IOBpredBGs.pop(); i -= 1
    lastIOBpredBG = float(jround(IOBpredBGs[-1]))
    lastCOBpredBG = None; lastUAMpredBG = None
    if meal['mealCOB'] > 0 and (ci > 0 or remainingCIpeak > 0):
        COBpredBGs = [jround(min(401.0, max(39.0, x)), 0) for x in COBpredBGs]
        i = len(COBpredBGs) - 1
        while i >= 13:
            if COBpredBGs[i - 1] != COBpredBGs[i]: break
            COBpredBGs.pop(); i -= 1
        lastCOBpredBG = COBpredBGs[-1]
        eventualBG = max(eventualBG, jround(COBpredBGs[-1], 0))
    if ci > 0 or remainingCIpeak > 0:
        if enableUAM:
            UAMpredBGs = [jround(min(401.0, max(39.0, x)), 0) for x in UAMpredBGs]
            i = len(UAMpredBGs) - 1
            while i >= 13:
                if UAMpredBGs[i - 1] != UAMpredBGs[i]: break
                UAMpredBGs.pop(); i -= 1
            lastUAMpredBG = UAMpredBGs[-1]
            eventualBG = max(eventualBG, jround(UAMpredBGs[-1], 0))
    minIOBPredBG = max(39.0, minIOBPredBG)
    minCOBPredBG = max(39.0, minCOBPredBG)
    minUAMPredBG = max(39.0, minUAMPredBG)
    minPredBG = jround(minIOBPredBG, 0)
    fSensBG = min(minPredBG, bg)
    future_sens = 0.0
    if dyn:
        if bg > target_bg and -3 < delta < 3 and -3 < gs['shortAvgDelta'] < 3 and eventualBG > target_bg and eventualBG < bg:
            future_sens = jround(1800 / (math.log(((fSensBG * 0.5) + (bg * 0.5)) / idiv + 1) * TDD), 1)
        elif (delta > 0 and eventualBG > target_bg) or eventualBG > bg:
            future_sens = jround(1800 / (math.log(bg / idiv + 1) * TDD), 1)
        else:
            future_sens = jround(1800 / (math.log(fSensBG / idiv + 1) * TDD), 1)
    fractionCarbsLeft = meal['mealCOB'] / meal['carbs'] if meal['carbs'] else float('nan')
    if minUAMPredBG < 999 and minCOBPredBG < 999:
        avgPredBG = jround((1 - fractionCarbsLeft) * UAMpredBG + fractionCarbsLeft * COBpredBG, 0)
    elif minCOBPredBG < 999:
        avgPredBG = jround((IOBpredBG + COBpredBG) / 2.0, 0)
    elif minUAMPredBG < 999:
        avgPredBG = jround((IOBpredBG + UAMpredBG) / 2.0, 0)
    else:
        avgPredBG = jround(IOBpredBG, 0)
    if minZTGuardBG > avgPredBG:
        avgPredBG = minZTGuardBG
    if cid > 0.0 or remainingCIpeak > 0:
        if enableUAM:
            minGuardBG = fractionCarbsLeft * minCOBGuardBG + (1 - fractionCarbsLeft) * minUAMGuardBG
        else:
            minGuardBG = minCOBGuardBG
    elif enableUAM:
        minGuardBG = minUAMGuardBG
    else:
        minGuardBG = minIOBGuardBG
    minGuardBG = jround(minGuardBG, 0)
    minZTUAMPredBG = minUAMPredBG
    if minZTGuardBG < threshold:
        minZTUAMPredBG = (minUAMPredBG + minZTGuardBG) / 2.0
    elif minZTGuardBG < target_bg:
        blendPct = (minZTGuardBG - threshold) / (target_bg - threshold)
        blended = minUAMPredBG * blendPct + minZTGuardBG * (1 - blendPct)
        minZTUAMPredBG = (minUAMPredBG + blended) / 2.0
    elif minZTGuardBG > minUAMPredBG:
        minZTUAMPredBG = (minUAMPredBG + minZTGuardBG) / 2.0
    minZTUAMPredBG = jround(minZTUAMPredBG, 0)
    if meal['carbs'] != 0.0:
        if not enableUAM and minCOBPredBG < 999:
            minPredBG = jround(max(minIOBPredBG, minCOBPredBG), 0)
        elif minCOBPredBG < 999:
            blendedMinPredBG = fractionCarbsLeft * minCOBPredBG + (1 - fractionCarbsLeft) * minZTUAMPredBG
            minPredBG = jround(max(minIOBPredBG, max(minCOBPredBG, blendedMinPredBG)), 0)
        elif enableUAM:
            minPredBG = minZTUAMPredBG
        else:
            minPredBG = minGuardBG
    elif enableUAM:
        minPredBG = jround(max(minIOBPredBG, minZTUAMPredBG), 0)
    minPredBG = min(minPredBG, avgPredBG)
    if maxCOBPredBG > bg:
        minPredBG = min(minPredBG, maxCOBPredBG)
    out.update(dict(bgi=bgi, deviation=deviation, naive_eventualBG=naive_eventualBG, eventualBG=eventualBG,
                    minPredBG=minPredBG, minGuardBG=minGuardBG, future_sens=future_sens, target_bg=target_bg,
                    threshold=threshold, basal=basal, lastIOBpredBG=lastIOBpredBG, lastUAMpredBG=lastUAMpredBG,
                    lastCOBpredBG=lastCOBpredBG, tier_m=tier_m))
    carbsReqBG = naive_eventualBG
    if carbsReqBG < 40:
        carbsReqBG = min(minGuardBG, carbsReqBG)
    if enableSMB and minGuardBG < threshold:
        enableSMB = False
    if maxDelta > 0.20 * bg:
        enableSMB = False
    out['enableSMB'] = enableSMB

    def maxSafeBasal():
        return min(p['max_basal'], min(p['max_daily_safety_multiplier'] * p['max_daily_basal'], p['current_basal_safety_multiplier'] * p['current_basal']))

    def setTemp(rate, duration, path):
        msb = maxSafeBasal()
        if rate < 0: rate = 0.0
        elif rate > msb: rate = msb
        out['path'] = path
        if ct['duration'] > (duration - 10) and ct['duration'] <= 120 and rate <= ct['rate'] * 1.2 and rate >= ct['rate'] * 0.8 and duration > 0:
            out['rate'] = None; out['duration'] = None; out['keep'] = True
            return out
        out['rate'] = rate; out['duration'] = duration
        return out

    out.setdefault('units', 0.0)
    out.setdefault('insulinReq', 0.0)
    if bg < threshold or minGuardBG < threshold:
        if not (bg < threshold and iob_data['iob'] < -p['current_basal'] * 20 / 60 and minDelta > 0 and minDelta > expectedDelta):
            bgUndershoot = target_bg - minGuardBG
            w = bgUndershoot / sens
            d = jround(60 * w / p['current_basal'])
            d = jround(d / 30.0) * 30
            d = min(120, max(30, d))
            return setTemp(0.0, d, 'guard')
    if eventualBG < min_bg:
        out['path'] = 'eventual<min'
        return out
    if minDelta < expectedDelta:
        if not (microBolusAllowed and enableSMB):
            out['path'] = 'falling-not-smb'
            return out
    if min(eventualBG, minPredBG) < max_bg:
        if not (microBolusAllowed and enableSMB):
            out['path'] = 'inrange-not-smb'
            return out
    if iob_data['iob'] > max_iob:
        out['path'] = 'maxiob'
        return out
    if dyn:
        insulinReq = jround((min(minPredBG, eventualBG) - target_bg) / future_sens, 2)
    else:
        insulinReq = jround((min(minPredBG, eventualBG) - target_bg) / sens, 2)
    if insulinReq > max_iob - iob_data['iob']:
        insulinReq = max_iob - iob_data['iob']
    rate = basal + 2 * insulinReq
    insulinReq = jround(insulinReq, 3)
    out['insulinReq'] = insulinReq
    out['path'] = 'high'
    if microBolusAllowed and enableSMB and bg > threshold:
        mealInsulinReq = jround(meal['mealCOB'] / carbRatio, 3)
        if iob_data['iob'] > mealInsulinReq and iob_data['iob'] > 0:
            maxBolus = jround(p['current_basal'] * p['maxUAMSMBBasalMinutes'] / 60, 1)
        else:
            maxBolus = jround(p['current_basal'] * p['maxSMBBasalMinutes'] / 60, 1)
        roundSMBTo = 1 / p['bolus_increment']
        microBolus = math.floor(min(insulinReq / 2, maxBolus) * roundSMBTo) / roundSMBTo
        out['microBolus'] = microBolus
        out['maxBolus'] = maxBolus
        w = (target_bg - (naive_eventualBG + minIOBPredBG) / 2.0) / sens
        d = jround(60 * w / p['current_basal'])
        if insulinReq > 0 and microBolus < p['bolus_increment']:
            d = 0
        smbLow = 0.0
        if d <= 0:
            d = 0
        elif d >= 30:
            d = jround(d / 30.0) * 30
            d = min(60, max(0, d))
        else:
            smbLow = jround(basal * d / 30.0, 2)
            d = 30
        lastBolusAge = (currentTime - iob_data['lastBolusTime']) / 1000.0
        SMBInterval = min(10, max(1, p['SMBInterval'])) * 60.0
        if lastBolusAge > SMBInterval - 6.0:
            if microBolus > 0:
                out['units'] = microBolus
        else:
            out['smbWait'] = True
        if d > 0:
            out['rate'] = smbLow; out['duration'] = d; out['path'] = 'high-smb-lowtemp'
            return out
    msb = maxSafeBasal()
    if rate > msb:
        rate = msb
    insulinScheduled = ct['duration'] * (ct['rate'] - basal) / 60
    out['rateReq'] = rate
    if insulinScheduled >= insulinReq * 2:
        return setTemp(rate, 30, 'high')
    if ct['duration'] == 0:
        return setTemp(rate, 30, 'high')
    if ct['duration'] > 5 and rate <= ct['rate']:
        out['keep'] = True
        return out
    return setTemp(rate, 30, 'high')
