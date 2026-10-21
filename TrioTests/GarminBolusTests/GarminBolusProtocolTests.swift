import CryptoKit
import Foundation
import Testing

@testable import Trio

@Suite("Garmin Bolus protocol") struct GarminBolusProtocolTests {
    private let key = SymmetricKey(data: Data((0 ..< 32).map { UInt8($0) }))

    @Test("HMAC matches the published vector") func hmacVector() {
        // Trio Companion's PROTOCOL.md vector, which CryptoKit and openssl agree on.
        let sig = GarminBolusProtocol.sign("bolus|a1b2c3d4|150|20|1760000000", key: key)
        #expect(sig == "e3c8a5b8fd5ad73f8731a64e670c7e75c449225185572dcab3bd6db695836d3a")
    }

    @Test("A signed quote parses and verifies") func quoteRoundTrip() {
        let unsigned: [String: Any] = ["t": "quote", "id": "a1b2c3d4", "ts": 1_760_000_000, "u": 0, "c": 45]
        let string = "quote|a1b2c3d4|1760000000|0|45"
        var message = unsigned
        message["sig"] = GarminBolusProtocol.sign(string, key: key)
        let request = GarminBolusProtocol.Request(message: message)
        #expect(request?.kind == .quote)
        #expect(request?.signedString == string)
        #expect(request?.carbs == 45)
        #expect(GarminBolusProtocol.isSignatureValid(request!.signature, for: request!.signedString, key: key))
    }

    @Test("A tampered amount fails the signature") func tamper() {
        var message: [String: Any] = ["t": "quote", "id": "a1b2c3d4", "ts": 1_760_000_000, "u": 150, "c": 0]
        message["sig"] = GarminBolusProtocol.sign("quote|a1b2c3d4|1760000000|150|0", key: key)
        message["u"] = 1500
        let request = GarminBolusProtocol.Request(message: message)!
        #expect(!GarminBolusProtocol.isSignatureValid(request.signature, for: request.signedString, key: key))
    }

    @Test("Malformed requests are refused") func malformed() {
        #expect(GarminBolusProtocol.Request(message: ["t": "quote", "id": "zz", "ts": 1, "u": 0, "c": 0, "sig": "00"]) == nil)
        #expect(
            GarminBolusProtocol
                .Request(message: ["t": "quote", "id": "a1b2c3d4", "ts": 1, "u": -5, "c": 0, "sig": "00"]) == nil
        )
        #expect(
            GarminBolusProtocol
                .Request(message: ["t": "quote", "id": "a1b2c3d4", "ts": 1, "u": 20000, "c": 0, "sig": "00"]) == nil
        )
        #expect(GarminBolusProtocol.Request(message: ["t": "confirm", "id": "a1b2c3d4", "ts": 1, "sig": "00"]) == nil)
        #expect(GarminBolusProtocol.Request(message: ["t": "explode", "id": "a1b2c3d4", "ts": 1, "sig": "00"]) == nil)
        #expect(GarminBolusProtocol.Request(message: "status") == nil)
    }

    @Test("Only confirm and carbs change state") func stateChanging() {
        func make(_ t: String, _ extra: [String: Any] = [:]) -> GarminBolusProtocol.Request? {
            var m: [String: Any] = ["t": t, "id": "a1b2c3d4", "ts": 1, "sig": "00"]
            m.merge(extra) { $1 }
            return GarminBolusProtocol.Request(message: m)
        }
        #expect(make("confirm", ["q": "0011223344556677"])?.changesState == true)
        #expect(make("carbs", ["c": 10])?.changesState == true)
        #expect(make("quote", ["u": 0, "c": 10])?.changesState == false)
        #expect(make("bstatus")?.changesState == false)
        #expect(make("cancel")?.changesState == false)
    }

    // MARK: - Confirm rules

    private let t0 = Date(timeIntervalSince1970: 1_760_000_000)

    private func quote(wizard: Bool = true, reading: GarminBolusProtocol.Reading? = nil) -> GarminBolusProtocol.Quote {
        GarminBolusProtocol.Quote(
            id: "0011223344556677", createdAt: t0, fromWizard: wizard, insulin: 3, carbs: 45,
            reading: reading ?? .init(mgdl: 140, date: t0.addingTimeInterval(-120)),
            newestManualBolusAt: t0.addingTimeInterval(-3600), newestAnyBolusAt: t0.addingTimeInterval(-600)
        )
    }

    private func world(
        after seconds: TimeInterval = 30,
        reading: GarminBolusProtocol.Reading? = nil,
        manual: Date? = nil,
        any: Date? = nil
    ) -> GarminBolusProtocol.World {
        GarminBolusProtocol.World(
            now: t0.addingTimeInterval(seconds),
            reading: reading ?? .init(mgdl: 140, date: t0.addingTimeInterval(-120)),
            newestManualBolusAt: manual ?? t0.addingTimeInterval(-3600),
            newestAnyBolusAt: any ?? t0.addingTimeInterval(-600)
        )
    }

    @Test("Nothing changed: allowed") func unchanged() {
        #expect(GarminBolusProtocol.staleness(of: quote(), in: world()) == nil)
    }

    @Test("Older than three minutes: refused") func expired() {
        #expect(GarminBolusProtocol.staleness(of: quote(), in: world(after: 181)) != nil)
        #expect(GarminBolusProtocol.staleness(of: quote(), in: world(after: -5)) != nil)
    }

    @Test("A manual bolus since the quote: refused, worked out or named") func manualSince() {
        let w = world(manual: t0.addingTimeInterval(10), any: t0.addingTimeInterval(10))
        #expect(GarminBolusProtocol.staleness(of: quote(wizard: true), in: w) != nil)
        #expect(GarminBolusProtocol.staleness(of: quote(wizard: false), in: w) != nil)
    }

    @Test("An SMB since: refuses a worked-out dose, not a named one") func smbSince() {
        let w = world(any: t0.addingTimeInterval(10))
        #expect(GarminBolusProtocol.staleness(of: quote(wizard: true), in: w) != nil)
        #expect(GarminBolusProtocol.staleness(of: quote(wizard: false), in: w) == nil)
    }

    @Test("BG moved 20 or more on a newer reading: refused") func bgMoved() {
        let moved = world(reading: .init(mgdl: 160, date: t0.addingTimeInterval(20)))
        let small = world(reading: .init(mgdl: 155, date: t0.addingTimeInterval(20)))
        #expect(GarminBolusProtocol.staleness(of: quote(), in: moved) != nil)
        #expect(GarminBolusProtocol.staleness(of: quote(), in: small) == nil)
    }

    @Test("Priced with no reading, one arrives: refused") func readingArrived() {
        let q = GarminBolusProtocol.Quote(
            id: "0011223344556677", createdAt: t0, fromWizard: true, insulin: 3, carbs: 45,
            reading: nil, newestManualBolusAt: nil, newestAnyBolusAt: nil
        )
        let w = GarminBolusProtocol.World(
            now: t0.addingTimeInterval(30),
            reading: .init(mgdl: 140, date: t0.addingTimeInterval(10)),
            newestManualBolusAt: nil,
            newestAnyBolusAt: nil
        )
        #expect(GarminBolusProtocol.staleness(of: q, in: w) != nil)
    }
}
