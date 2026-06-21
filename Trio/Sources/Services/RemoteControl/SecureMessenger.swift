import CryptoSwift
import Foundation
import Security

struct SecureMessenger {
    private let sharedKey: [UInt8]

    init?(sharedSecret: String) {
        guard let secretData = sharedSecret.data(using: .utf8) else {
            return nil
        }
        sharedKey = Array(secretData.sha256())
    }

    /// Encrypts a command for the sender side (a second phone commanding this one).
    /// Mirrors `decrypt` exactly: JSON-encode the payload, AES-256-GCM with a fresh
    /// random 12-byte nonce, prepend the nonce, base64. The receiver above splits the
    /// nonce back off and decrypts with the same SHA-256(sharedSecret) key.
    func encrypt(_ payload: CommandPayload) throws -> String {
        let plaintext = try JSONEncoder().encode(payload)

        var nonce = [UInt8](repeating: 0, count: 12)
        guard SecRandomCopyBytes(kSecRandomDefault, nonce.count, &nonce) == errSecSuccess else {
            throw NSError(
                domain: "SecureMessenger",
                code: 102,
                userInfo: [NSLocalizedDescriptionKey: "Failed to generate a secure nonce"]
            )
        }

        let gcm = GCM(iv: nonce, mode: .combined)
        let aes = try AES(key: sharedKey, blockMode: gcm, padding: .noPadding)
        let ciphertextAndTag = try aes.encrypt(Array(plaintext))

        let combined = Data(nonce) + Data(ciphertextAndTag)
        return combined.base64EncodedString()
    }

    func decrypt(base64EncodedString: String) throws -> CommandPayload {
        guard let combinedData = Data(base64Encoded: base64EncodedString) else {
            throw NSError(domain: "SecureMessenger", code: 100, userInfo: [NSLocalizedDescriptionKey: "Invalid Base64 string"])
        }

        let nonceSize = 12
        guard combinedData.count > nonceSize else {
            throw NSError(
                domain: "SecureMessenger",
                code: 101,
                userInfo: [NSLocalizedDescriptionKey: "Encrypted data is too short to contain a nonce"]
            )
        }
        let nonce = Array(combinedData.prefix(nonceSize))
        let ciphertextAndTag = Array(combinedData.suffix(from: nonceSize))
        let gcm = GCM(iv: nonce, mode: .combined)
        let aes = try AES(key: sharedKey, blockMode: gcm, padding: .noPadding)
        let decryptedBytes = try aes.decrypt(ciphertextAndTag)
        let decryptedData = Data(decryptedBytes)
        let commandPayload = try JSONDecoder().decode(CommandPayload.self, from: decryptedData)

        return commandPayload
    }
}
