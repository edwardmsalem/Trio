import CryptoKit
import Foundation

/// The messages the Garmin Bolus app sends Trio, and the rules for answering them.
///
/// Everything here is plain values with no Trio state, so the parsing, the signatures
/// and the confirm rules can be tested on their own.
///
/// Every request is a dictionary carrying a type, a random id, the watch's clock and an
/// HMAC-SHA256 signature in lowercase hex:
///
///     pair     "pair|<id>|<ts>"                  signed with the PIN, once
///     quote    "quote|<id>|<ts>|<u>|<c>"         u = hundredths of a unit, 0 = work it out
///     confirm  "confirm|<id>|<ts>|<q>"           q = the quote id Trio gave back
///     carbs    "carbs|<id>|<ts>|<c>"
///     bstatus  "bstatus|<id>|<ts>"
///     cancel   "cancel|<id>|<ts>"
///
/// Every reply is `["t": "<type>Ack", "id": <request id>, "code": Int, ...]`. The code
/// reads like HTTP so the watch keeps one table of words for it: 200 is an answer, a
/// 4xx is a clean refusal before anything happened, a 5xx means Trio may have acted.
/// A refusal that is an answer -- the pump is suspended, the quote went stale -- comes
/// back as 200 with "refused" or "error", the same shape the AAPS version uses, so the
/// watch's screens are identical for both.
enum GarminBolusProtocol {
    /// How far the watch clock may be from the phone's, either way.
    static let maxClockSkew: TimeInterval = 60
    /// Request bounds, far above any real dose. Anything larger is malformed.
    static let maxCentiUnits = 10000
    static let maxCarbGrams = 1000

    enum Kind: String {
        case pair
        case quote
        case confirm
        case carbs
        case bstatus
        case cancel
    }

    struct Request: Equatable {
        let kind: Kind
        let id: String
        let timestamp: Int
        let signature: String
        /// quote: insulin in hundredths of a unit.
        var centiUnits = 0
        /// quote and carbs: grams.
        var carbs = 0
        /// confirm: the quote being approved.
        var quoteID = ""

        var units: Decimal { Decimal(centiUnits) / 100 }

        var signedString: String {
            switch kind {
            case .bstatus,
                 .cancel,
                 .pair:
                return "\(kind.rawValue)|\(id)|\(timestamp)"
            case .quote:
                return "quote|\(id)|\(timestamp)|\(centiUnits)|\(carbs)"
            case .confirm:
                return "confirm|\(id)|\(timestamp)|\(quoteID)"
            case .carbs:
                return "carbs|\(id)|\(timestamp)|\(carbs)"
            }
        }

        /// Whether answering this changes anything. These are held to stricter replay
        /// rules: each must be newer than the last one accepted.
        var changesState: Bool { kind == .confirm || kind == .carbs }

        init?(message: Any) {
            guard let dict = message as? [String: Any],
                  let type = dict["t"] as? String, let kind = Kind(rawValue: type),
                  let id = dict["id"] as? String, GarminBolusProtocol.isValidID(id),
                  let ts = (dict["ts"] as? NSNumber)?.intValue,
                  let sig = dict["sig"] as? String
            else { return nil }
            self.kind = kind
            self.id = id
            timestamp = ts
            signature = sig.lowercased()

            switch kind {
            case .quote:
                guard let u = (dict["u"] as? NSNumber)?.intValue,
                      let c = (dict["c"] as? NSNumber)?.intValue,
                      (0 ... GarminBolusProtocol.maxCentiUnits).contains(u),
                      (0 ... GarminBolusProtocol.maxCarbGrams).contains(c)
                else { return nil }
                centiUnits = u
                carbs = c
            case .carbs:
                guard let c = (dict["c"] as? NSNumber)?.intValue,
                      (0 ... GarminBolusProtocol.maxCarbGrams).contains(c)
                else { return nil }
                carbs = c
            case .confirm:
                guard let q = dict["q"] as? String, GarminBolusProtocol.isValidID(q) else { return nil }
                quoteID = q
            case .bstatus,
                 .cancel,
                 .pair:
                break
            }
        }
    }

    /// The request type, if the message is one of ours at all. Used to route before
    /// parsing, so a malformed request still gets an answer instead of silence.
    static func kind(of message: Any) -> Kind? {
        ((message as? [String: Any])?["t"] as? String).flatMap(Kind.init(rawValue:))
    }

    static func isValidID(_ id: String) -> Bool {
        (8 ... 32).contains(id.count) && id.allSatisfy(\.isHexDigit)
    }

    static func isSignatureValid(_ signature: String, for string: String, key: SymmetricKey) -> Bool {
        guard let mac = Data(garminHex: signature) else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(mac, authenticating: Data(string.utf8), using: key)
    }

    static func sign(_ string: String, key: SymmetricKey) -> String {
        Data(HMAC<SHA256>.authenticationCode(for: Data(string.utf8), using: key)).garminHex
    }

    static func newQuoteID() -> String {
        SymmetricKey(size: .bits128).withUnsafeBytes { Data($0) }.garminHex
    }

    // MARK: - Confirm rules

    /// A glucose reading, mg/dl.
    struct Reading: Equatable {
        let mgdl: Int
        let date: Date
    }

    /// What was true when a dose was priced.
    struct Quote: Equatable {
        let id: String
        let createdAt: Date
        /// Trio worked the dose out from carbs, rather than the user naming it.
        let fromWizard: Bool
        let insulin: Decimal
        let carbs: Int
        let reading: Reading?
        let newestManualBolusAt: Date?
        let newestAnyBolusAt: Date?
    }

    /// What is true at the moment of confirming.
    struct World: Equatable {
        let now: Date
        let reading: Reading?
        let newestManualBolusAt: Date?
        let newestAnyBolusAt: Date?
    }

    /// How long a quote stands. The watch drops its own copy sooner and asks again;
    /// this is the phone's backstop.
    static let quoteMaxAge: TimeInterval = 180
    /// A new reading this far from the priced one, in mg/dl, voids the quote.
    static let bgChangeMgdl = 20

    /// Whether the world moved between pricing a dose and confirming it.
    ///
    /// The phone's own bolus screen prices and gives in one breath, so it never needs
    /// this. The watch leaves a gap, and in that gap the phone can bolus, the loop can
    /// SMB and a reading can land. Each refuses with a reason short enough for the
    /// watch to show, and the watch's answer is to ask again.
    static func staleness(of quote: Quote, in world: World) -> String? {
        let age = world.now.timeIntervalSince(quote.createdAt)
        if age < 0 || age > quoteMaxAge { return "Quote expired, ask again" }

        // A manual bolus since pricing: giving this too is the double dose. Newer than
        // the newest at quote time also catches a pump that writes its record late.
        if let manual = world.newestManualBolusAt, manual > (quote.newestManualBolusAt ?? .distantPast) {
            return "Insulin given since quote, ask again"
        }
        // A worked-out dose subtracted the IOB of that moment, so any bolus since, an
        // SMB included, means it no longer stands. A dose the user named is theirs.
        if quote.fromWizard, let any = world.newestAnyBolusAt, any > (quote.newestAnyBolusAt ?? .distantPast) {
            return "Insulin given since quote, ask again"
        }

        if let then = quote.reading, let now = world.reading, now.date > then.date,
           abs(now.mgdl - then.mgdl) >= bgChangeMgdl
        {
            return "BG changed, ask again"
        }
        // Priced with no reading at all, and one has arrived since: the dose ignored it.
        if quote.fromWizard, quote.reading == nil, let now = world.reading, now.date > quote.createdAt {
            return "BG changed, ask again"
        }
        return nil
    }
}
