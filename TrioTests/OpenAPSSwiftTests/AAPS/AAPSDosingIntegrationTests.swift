import Foundation
import Testing
@testable import Trio

/// Runs the full Swift pipeline on the synthetic parity scenarios with the new modes switched on.
@Suite(
    "AAPS dosing and stock tiers in the pipeline",
    .serialized,
    .enabled(if: ParityEnv.isPinned, "scenarios require the process to run in \(ParityEnv.timeZoneIdentifier)")
) struct AAPSDosingIntegrationTests {
    static func scenario(_ name: String, vars transform: (inout TrioCustomOrefVariables) -> Void) -> ParityScenario {
        let s = ParityScenarios.build(name)
        var vars = s.orefVariables
        transform(&vars)
        return ParityScenario(
            name: s.name, clock: s.clock, glucose: s.glucose, pumpHistory: s.pumpHistory, carbs: s.carbs,
            tempTargets: s.tempTargets, preferences: s.preferences, orefVariables: vars, currentTemp: s.currentTemp,
            reservoir: s.reservoir, pumpSettings: s.pumpSettings, bgTargets: s.bgTargets, basalProfile: s.basalProfile,
            isf: s.isf, carbRatios: s.carbRatios
        )
    }

    static let noTdd = AAPSDynamicISF.TddInputs()

    /// The scenario with a running temp target (started 10 minutes ago) and AAPS mode on.
    static func withTempTarget(
        _ name: String,
        target: Decimal,
        allowSMBWithHighTemptarget: Bool
    ) -> ParityScenario {
        let s = scenario(name) { $0.aapsDosing = AAPSDosingContext(settings: .default, tdd: noTdd) }
        var preferences = s.preferences
        preferences.allowSMBWithHighTemptarget = allowSMBWithHighTemptarget
        let tempTarget = TempTarget(
            name: "Home", createdAt: s.clock.addingTimeInterval(-10 * 60), targetTop: target, targetBottom: target,
            duration: 60, enteredBy: TempTarget.local, reason: TempTarget.custom, isPreset: false, enabled: true,
            halfBasalTarget: nil
        )
        return ParityScenario(
            name: s.name, clock: s.clock, glucose: s.glucose, pumpHistory: s.pumpHistory, carbs: s.carbs,
            tempTargets: [tempTarget], preferences: preferences, orefVariables: s.orefVariables,
            currentTemp: s.currentTemp, reservoir: s.reservoir, pumpSettings: s.pumpSettings, bgTargets: s.bgTargets,
            basalProfile: s.basalProfile, isf: s.isf, carbRatios: s.carbRatios
        )
    }

    @Test("a temp target is the AAPS target, and a high one stops SMB unless allowed") func aapsTempTarget() throws {
        let name = "high-bg-rising-smb"
        let plain = try #require(try ParityScenarios.runPipeline(Self.scenario(name) {
            $0.aapsDosing = AAPSDosingContext(settings: .default, tdd: Self.noTdd)
        }).determination)
        #expect((plain.units ?? 0) > 0, "baseline must SMB: \(plain.reason)")

        let high = try ParityScenarios.runPipeline(Self.withTempTarget(name, target: 140, allowSMBWithHighTemptarget: false))
        #expect(high.profile.temptargetSet == true)
        #expect(high.profile.minBg == 140)
        let blocked = try #require(high.determination)
        #expect(blocked.reason.hasPrefix("AAPS dosing"), "\(blocked.reason)")
        #expect(blocked.current_target == 140)
        #expect((blocked.units ?? 0) == 0, "high temp target with SMB not allowed: \(blocked.reason)")

        let allowed = try #require(try ParityScenarios.runPipeline(
            Self.withTempTarget(name, target: 140, allowSMBWithHighTemptarget: true)
        ).determination)
        #expect(allowed.current_target == 140)
        #expect((allowed.units ?? 0) > 0, "high temp target with SMB allowed: \(allowed.reason)")

        // 100 mg/dL is AAPS's "normal" target, so it is not a high temp target
        let normal = try #require(try ParityScenarios.runPipeline(
            Self.withTempTarget(name, target: 100, allowSMBWithHighTemptarget: false)
        ).determination)
        #expect(normal.current_target == 100)
        #expect((normal.units ?? 0) > 0, "100 is not a high temp target: \(normal.reason)")
    }

    @Test("AAPS mode runs the AAPS core and stays inside the safety caps") func aapsModeRuns() throws {
        for name in ["high-bg-rising-smb", "low-bg-falling", "post-meal-cob-active", "override-active"] {
            let s = Self.scenario(name) { $0.aapsDosing = AAPSDosingContext(settings: .default, tdd: Self.noTdd) }
            let out = try ParityScenarios.runPipeline(s)
            let d = try #require(out.determination)
            #expect(d.reason.hasPrefix("AAPS dosing (profile ISF"), "\(name): \(d.reason)")
            if let rate = d.rate {
                #expect(rate <= (try #require(out.profile.maxBasal)))
                #expect(rate >= 0)
            }
            if let units = d.units { #expect(units <= out.profile.maxIob) }
        }
    }

    @Test("AAPS mode switched off gives exactly the stock determination") func aapsModeOffIsStock() throws {
        for name in ParityScenarios.allNames {
            let stock = try ParityScenarios.runPipeline(ParityScenarios.build(name)).determination
            var settings = AAPSDosingSettings.default
            settings.enabled = false
            let off = try ParityScenarios
                .runPipeline(Self.scenario(name) { $0.aapsDosing = AAPSDosingContext(settings: settings, tdd: Self.noTdd) })
                .determination
            #expect(stock?.reason == off?.reason, "\(name)")
            #expect(stock?.units == off?.units, "\(name)")
            #expect(stock?.rate == off?.rate, "\(name)")
            #expect(stock?.duration == off?.duration, "\(name)")
            #expect(stock?.eventualBG == off?.eventualBG, "\(name)")
        }
    }

    @Test("AAPS mode with 7 days of TDD runs Dynamic ISF") func aapsDynamicIsf() throws {
        let tdd = AAPSDynamicISF.TddInputs(tdd1D: 40, tdd7D: 42, tddLast24H: 41, tddLast4H: 6, tddLast8to4H: 6)
        let s = Self.scenario("high-bg-rising-smb") { $0.aapsDosing = AAPSDosingContext(settings: .default, tdd: tdd) }
        let d = try #require(try ParityScenarios.runPipeline(s).determination)
        #expect(d.reason.hasPrefix("AAPS dosing (Dynamic ISF, TDD "), "\(d.reason)")
        #expect(d.reason.contains("Dosing sensitivity: "))
    }

    @Test("stock mode applies the ISF tier before dynamic ISF and autosens") func stockTiersApply() throws {
        let name = "high-bg-rising-smb"
        let stock = try #require(try ParityScenarios.runPipeline(ParityScenarios.build(name)).determination)
        let tiered = try #require(try ParityScenarios.runPipeline(Self.scenario(name) {
            $0.isfTiersEnabled = true
            $0.isfTiers = [InsulinSensitivityTier(bgMin: 0, bgMax: 400, isfMultiplier: 0.8)]
            $0.carbTierEnabled = true
        }).determination)
        #expect(tiered.reason.contains("ISF tier: x0.8"), "\(tiered.reason)")
        let stockIsf = try #require(stock.isf)
        let tieredIsf = try #require(tiered.isf)
        #expect(tieredIsf < stockIsf)
        #expect(abs(tieredIsf - stockIsf * 0.8) <= 1)
        #expect(try #require(tiered.carbRatio) < (try #require(stock.carbRatio)))
    }

    @Test("AAPS mode with Trio's history uses AAPS's own IOB, COB and glucose status") func aapsModeOwnInputs() throws {
        for name in ["high-bg-rising-smb", "low-bg-falling", "post-meal-cob-active", "override-active"] {
            let base = ParityScenarios.build(name)
            let history = AAPSHistory.from(
                pumpHistory: base.pumpHistory,
                carbs: base.carbs,
                glucose: base.glucose,
                basalProfile: base.basalProfile,
                now: base.clock
            )
            let s = Self.scenario(name) {
                $0.aapsDosing = AAPSDosingContext(settings: .default, tdd: Self.noTdd, history: history)
            }
            let out = try ParityScenarios.runPipeline(s)
            let d = try #require(out.determination)
            #expect(d.reason.hasPrefix("AAPS dosing (profile ISF"), "\(name): \(d.reason)")
            if let rate = d.rate { #expect(rate <= (try #require(out.profile.maxBasal)) && rate >= 0) }
            if let units = d.units { #expect(units <= out.profile.maxIob) }

            let nowMs = Int64((base.clock.timeIntervalSince1970 * 1000).rounded())
            let curve = AAPSIob.Curve(diaHours: max(Double(truncating: (out.profile.dia ?? 5) as NSNumber), 5), peakMinutes: 75)
            let iob = AAPSIob.iobArray(
                history: history, now: nowMs, autosensRatio: Double(truncating: out.autosens.ratio as NSNumber), curve: curve
            )
            let ran = d.eventualBG != nil
            if ran {
                let reported = try #require(d.iob.map { Double(truncating: $0 as NSNumber) })
                #expect(abs(reported - iob[0].iob) < 1E-9, "\(name)")
            }
        }
    }
}
