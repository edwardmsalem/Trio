import Foundation
import Testing
@testable import Trio

/// Proves the AAPS dosing mode gives AAPS's own decisions on Eddie's real loop runs.
///
/// The runs are personal health data, kept outside git. Set `AAPS_ORACLE_DIR` to the private
/// folder holding `aps.jsonl` (and `logs/` for the Dynamic ISF check). When running through
/// xcodebuild, pass it as `TEST_RUNNER_AAPS_ORACLE_DIR=<folder>`. Without it these tests skip.
@Suite("AAPS dosing equivalence (private data)", .serialized) struct AAPSEquivalenceTests {
    static var dataURL: URL? { AAPSEquivalence.jsonlURL() }
    static var logsURL: URL? {
        guard let dir = ProcessInfo.processInfo.environment["AAPS_ORACLE_DIR"] else { return nil }
        let url = URL(fileURLWithPath: dir).appendingPathComponent("logs")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    @Test(
        "every logged AAPS loop run gets the same dose",
        .enabled(if: AAPSEquivalenceTests.dataURL != nil, "set AAPS_ORACLE_DIR to the private oracle folder")
    ) func loopRunsMatchAAPS() throws {
        let records = try AAPSEquivalence.loadRecords(from: #require(Self.dataURL))
        let report = AAPSEquivalence.compare(records: records)
        print("AAPS equivalence\n" + report.summary)
        for m in report.mismatches.prefix(20) {
            print("mismatch ts=\(m.ts) \(m.field): AAPS \(m.expected) | Trio \(m.actual)")
        }
        #expect(report.checked > 0)
        #expect(report.doseIdentical == report.checked)
        #expect(report.unitsEqual == report.checked)
        #expect(report.tempEqual == report.checked)
        #expect(report.insulinReqEqual == report.checked)
        #expect(report.eventualWithin1 == report.checked)
        #expect(report.minGuardEqual == report.checked)
        #expect(report.minPredEqual == report.checked)
        #expect(report.dosingSensEqual == report.checked)
        #expect(report.carbsReqEqual == report.checked)
        #expect(report.branchEqual == report.checked)
        #expect(report.predictionsEqual == report.checked)
    }

    @Test(
        "AAPS Dynamic ISF TDD blend, variable ISF and autosens match the logs",
        .enabled(if: AAPSEquivalenceTests.logsURL != nil, "set AAPS_ORACLE_DIR to the private oracle folder")
    ) func dynamicIsfMatchesAAPS() throws {
        let report = AAPSEquivalence.compareDynamicIsf(logsDirectory: try #require(Self.logsURL))
        print("AAPS Dynamic ISF\n" + report.summary)
        for m in report.mismatches.prefix(20) { print("mismatch \(m)") }
        #expect(report.lines > 0)
        #expect(report.tddEqual == report.lines)
        #expect(report.variableSensEqual == report.lines)
        #expect(report.paired > 0)
        #expect(report.autosensEqual == report.paired)
        #expect(report.profileEqual == report.paired)
    }
}
