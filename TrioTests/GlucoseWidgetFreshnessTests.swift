import Foundation
import Testing
@testable import Trio

/// The home/lock-screen glucose widget must judge age from the READING time and
/// the timeline entry's date, never the moment a snapshot was written.
@Suite("Glucose widget freshness") struct GlucoseWidgetFreshnessTests {
    private func snapshot(readingAt date: Date) -> GlucoseWidgetData {
        GlucoseWidgetData(glucose: "120", trend: "→", delta: "+2", colorString: "#ffffff", date: date)
    }

    @Test("Ages through fresh, aging, stale and very stale by reading time") func thresholds() {
        let reading = Date(timeIntervalSince1970: 1_000_000)
        let data = snapshot(readingAt: reading)
        #expect(data.freshness(at: reading.addingTimeInterval(4 * 60)) == .fresh)
        #expect(data.freshness(at: reading.addingTimeInterval(10 * 60)) == .fresh)
        #expect(data.freshness(at: reading.addingTimeInterval(12 * 60)) == .aging)
        #expect(data.freshness(at: reading.addingTimeInterval(16 * 60)) == .stale)
        #expect(data.freshness(at: reading.addingTimeInterval(31 * 60)) == .veryStale)
        #expect(data.freshness(at: reading.addingTimeInterval(2 * 60 * 60)) == .veryStale)
    }

    @Test("A reading in the future of the clock counts as fresh") func clockSkew() {
        let reading = Date(timeIntervalSince1970: 1_000_000)
        #expect(snapshot(readingAt: reading).freshness(at: reading.addingTimeInterval(-60)) == .fresh)
    }

    @Test("Snapshots written before lastLoopDate existed still decode") func decodesOldSnapshot() throws {
        let json = "{\"glucose\":\"120\",\"trend\":\"→\",\"delta\":\"+2\",\"colorString\":\"#ffffff\",\"date\":0}"
        let decoded = try JSONDecoder().decode(GlucoseWidgetData.self, from: Data(json.utf8))
        #expect(decoded.lastLoopDate == nil)
        #expect(decoded.glucose == "120")
    }
}

@Suite("Glucose widget reload budget") struct GlucoseWidgetReloadPolicyTests {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func shown(
        _ minutes: Double,
        _ mgdl: Int = 120,
        trend: String = "→",
        inRange: Bool = true,
        units: String = "mg/dL"
    ) -> GlucoseWidgetReloadPolicy.Shown {
        .init(readingDate: t0.addingTimeInterval(minutes * 60), glucoseMgdL: mgdl, trend: trend, inRange: inRange, units: units)
    }

    private func reload(
        _ new: GlucoseWidgetReloadPolicy.Shown,
        after last: GlucoseWidgetReloadPolicy.Shown?,
        active: Bool = false,
        leaving: Bool = false
    ) -> Bool
    {
        GlucoseWidgetReloadPolicy.shouldReload(new: new, last: last, appIsActive: active, enteringBackground: leaving)
    }

    @Test("First reading always reloads, a repeat never does") func firstAndDuplicate() {
        #expect(reload(shown(0), after: nil))
        #expect(!reload(shown(0), after: shown(0)))
        #expect(!reload(shown(0), after: shown(0), active: true))
        #expect(!reload(shown(0), after: shown(0), leaving: true))
    }

    @Test("Steady background readings are held back until 14 minutes") func steadyBackground() {
        let last = shown(0, 120)
        #expect(!reload(shown(5, 122), after: last))
        #expect(!reload(shown(10, 118), after: last))
        #expect(reload(shown(15, 121), after: last))
    }

    @Test("Meaningful change, range crossing, trend or unit change reload at once") func meaningful() {
        let last = shown(0, 120)
        #expect(reload(shown(5, 131), after: last))
        #expect(reload(shown(5, 110), after: last))
        #expect(reload(shown(5, 122, inRange: false), after: last))
        #expect(reload(shown(5, 122, trend: "↗"), after: last))
        #expect(reload(shown(5, 122, units: "mmol/L"), after: last))
    }

    @Test("Foreground and entering background reload any new reading") func foregroundAndLeaving() {
        let last = shown(0, 120)
        #expect(reload(shown(5, 121), after: last, active: true))
        #expect(reload(shown(5, 121), after: last, leaving: true))
    }

    @Test("The hold-back gap stays under the stale threshold") func gapUnderStale() {
        #expect(GlucoseWidgetReloadPolicy.maxInterval < GlucoseWidgetData.staleAfter)
    }
}
