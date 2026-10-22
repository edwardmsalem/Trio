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
}
