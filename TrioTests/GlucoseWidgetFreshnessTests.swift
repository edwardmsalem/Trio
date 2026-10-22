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
        let json = #"{"glucose":"120","trend":"→","delta":"+2","colorString":"#ffffff","date":0}"#
        let decoded = try JSONDecoder().decode(GlucoseWidgetData.self, from: Data(json.utf8))
        #expect(decoded.lastLoopDate == nil)
        #expect(decoded.glucose == "120")
    }
}
