import Foundation
import Testing
@testable import Trio

/// The first launch after upgrading Eddie's phone from the 0.8.4 fork stalled for minutes:
/// the history feed replayed up to a week of old writes, several fetches ran at once over
/// the same backlog, and the store was too busy for the CGM, the loop or Home
/// (nightscout/Trio#1638). These pin the gate that lets one history fetch run at a time.
/// The launch behaviour itself (start at the current token) was checked end to end in the
/// simulator with a week of history: an in-memory test store shares the token key in
/// UserDefaults with the host app's own store, so it cannot be tested here.
@Suite("Persistent history at launch", .serialized) struct PersistentHistoryLaunchTests {
    @Test("Only one history fetch runs at a time") func gateAllowsOneFetch() async {
        let gate = HistoryFetchGate()
        #expect(await gate.begin() == true)
        #expect(await gate.begin() == false)
        #expect(await gate.begin() == false)
    }

    @Test("Requests made during a fetch collapse into one rerun") func gateRerunsOnce() async {
        let gate = HistoryFetchGate()
        _ = await gate.begin()
        _ = await gate.begin()
        _ = await gate.begin()
        #expect(await gate.finish() == true)
        #expect(await gate.finish() == false)
        #expect(await gate.begin() == true)
    }

    @Test("A quiet fetch finishes without a rerun") func gateQuietFinish() async {
        let gate = HistoryFetchGate()
        _ = await gate.begin()
        #expect(await gate.finish() == false)
        #expect(await gate.begin() == true)
    }
}
