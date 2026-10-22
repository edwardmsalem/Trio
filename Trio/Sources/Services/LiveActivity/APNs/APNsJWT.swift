import CryptoKit
import Foundation

/// Signs APNs provider tokens (ES256 JWTs) with an APNs auth key, so the app can
/// send Live Activity pushes to itself without a server. Modelled on LoopFollow's
/// JWTManager.
struct APNsJWTSigner {
    enum SignerError: Error, Equatable {
        case emptyKey
        case notBase64
        case invalidKey
    }

    let keyID: String
    let teamID: String
    let privateKey: P256.Signing.PrivateKey

    init(keyID: String, teamID: String, privateKey: P256.Signing.PrivateKey) {
        self.keyID = keyID
        self.teamID = teamID
        self.privateKey = privateKey
    }

    /// Accepts the contents of an `AuthKey_XXXX.p8` file, with or without the PEM
    /// armour lines and line breaks.
    init(keyID: String, teamID: String, p8: String) throws {
        self.init(keyID: keyID, teamID: teamID, privateKey: try Self.parsePrivateKey(p8))
    }

    static func parsePrivateKey(_ p8: String) throws -> P256.Signing.PrivateKey {
        let body = p8
            .components(separatedBy: .newlines)
            .filter { !$0.hasPrefix("-----") }
            .joined()
            .filter { !$0.isWhitespace }
        guard !body.isEmpty else { throw SignerError.emptyKey }
        guard let der = Data(base64Encoded: body) else { throw SignerError.notBase64 }
        do {
            return try P256.Signing.PrivateKey(derRepresentation: der)
        } catch {
            throw SignerError.invalidKey
        }
    }

    /// The signed token: `base64url(header).base64url(claims).base64url(r||s)`.
    func token(issuedAt: Date) throws -> String {
        let header = #"{"alg":"ES256","kid":"\#(keyID)"}"#
        let claims = #"{"iss":"\#(teamID)","iat":\#(Int(issuedAt.timeIntervalSince1970))}"#
        let signingInput = Self.base64URL(Data(header.utf8)) + "." + Self.base64URL(Data(claims.utf8))
        let signature = try privateKey.signature(for: Data(signingInput.utf8))
        return signingInput + "." + Self.base64URL(signature.rawRepresentation)
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Keeps one provider token for up to 50 minutes. APNs rejects tokens older than
/// an hour and also rejects a new token more often than every 20 minutes
/// (TooManyProviderTokenUpdates), so the token is reused until it ages out or
/// APNs refuses it.
final class APNsJWTCache {
    static let lifetime: TimeInterval = 50 * 60

    private let signer: APNsJWTSigner
    private let lock = NSLock()
    private var cached: (token: String, issuedAt: Date)?

    init(signer: APNsJWTSigner) {
        self.signer = signer
    }

    func token(now: Date = Date()) throws -> String {
        lock.lock()
        defer { lock.unlock() }
        if let cached, now.timeIntervalSince(cached.issuedAt) < Self.lifetime, now >= cached.issuedAt {
            return cached.token
        }
        let token = try signer.token(issuedAt: now)
        cached = (token, now)
        return token
    }

    func invalidate() {
        lock.lock()
        cached = nil
        lock.unlock()
    }
}

/// The APNs key baked in at build time (see LiveActivityAPNSKeys.swift, which CI
/// writes from the APNS_* secrets). `nil` when the build has no key, in which case
/// silent renewal hides itself and the Live Activity behaves as before.
enum LiveActivityAPNsCredentials {
    static let signer: APNsJWTSigner? = {
        let keyID = LiveActivityAPNSKeys.keyID
        let teamID = LiveActivityAPNSKeys.teamID
        guard !keyID.isEmpty, !teamID.isEmpty else { return nil }
        return try? APNsJWTSigner(keyID: keyID, teamID: teamID, p8: LiveActivityAPNSKeys.privateKeyBase64)
    }()

    static var isConfigured: Bool { signer != nil }
}
