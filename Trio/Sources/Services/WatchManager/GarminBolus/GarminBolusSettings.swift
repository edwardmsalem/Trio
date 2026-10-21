import CryptoKit
import Foundation

/// What the user has set for bolusing from the Garmin watch, and the key the paired
/// watch signs with.
///
/// The pairing design (a 4-digit PIN that is used once to hand the watch a random
/// 256-bit key, never again) and most of this file follow Nathan Solis's Trio
/// Companion for Garmin, MIT licensed: github.com/k9track/trio-garmin-companion.
enum GarminBolusSettings {
    static let enabledKey = "GarminBolus.enabled"
    static let maxBolusKey = "GarminBolus.maxBolus"
    static let maxCarbsKey = "GarminBolus.maxCarbs"
    static let failuresKey = "GarminBolus.authFailures"
    static let pairingUntilKey = "GarminBolus.pairingUntil"
    static let defaultMaxBolus: Double = 3
    static let defaultMaxCarbs: Double = 60
    /// Wrong PINs or signatures in a row before watch bolus switches itself off.
    static let maxAuthFailures = 5
    static let pairingWindow: TimeInterval = 120

    private static let pinKey = "GarminBolus.pin"
    private static let watchKeyKey = "GarminBolus.watchKey"

    /// This iPhone only, never synced to iCloud, readable after the first unlock so a
    /// request still works with the phone locked in a pocket.
    private static let keychain = BaseKeychain(
        synchronizable: false,
        accessibilityLevel: .afterFirstUnlockThisDeviceOnly
    )

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: enabledKey)
    }

    static func setEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: enabledKey)
    }

    /// The most one watch request may give. The pump's Max Bolus, Max IOB and the
    /// recent-bolus check all still apply on top of it.
    static var maxBolus: Decimal {
        Decimal(UserDefaults.standard.object(forKey: maxBolusKey) as? Double ?? defaultMaxBolus)
    }

    static var maxCarbs: Decimal {
        Decimal(UserDefaults.standard.object(forKey: maxCarbsKey) as? Double ?? defaultMaxCarbs)
    }

    static func isValidPIN(_ pin: String) -> Bool {
        pin.count == 4 && pin.allSatisfy { ("0" ... "9").contains($0) }
    }

    static var pin: String? {
        get {
            let value: String? = keychain.getValue(String.self, forKey: pinKey)
            return value.flatMap { isValidPIN($0) ? $0 : nil }
        }
        set {
            if let newValue { keychain.setValue(newValue, forKey: pinKey) }
            else { keychain.removeObject(forKey: pinKey) }
        }
    }

    /// The random key the paired watch signs every request with.
    static var watchKey: SymmetricKey? {
        let hex: String? = keychain.getValue(String.self, forKey: watchKeyKey)
        guard let hex, hex.count == 64, let data = Data(garminHex: hex) else { return nil }
        return SymmetricKey(data: data)
    }

    static var isPaired: Bool { watchKey != nil }

    /// Makes and stores a new key and returns it as hex for the watch.
    static func makeWatchKey() -> String {
        let key = SymmetricKey(size: .bits256)
        let hex = key.withUnsafeBytes { Data($0) }.garminHex
        keychain.setValue(hex, forKey: watchKeyKey)
        return hex
    }

    static func unpair() {
        keychain.removeObject(forKey: watchKeyKey)
        setEnabled(false)
    }

    static var isPairingOpen: Bool {
        Date().timeIntervalSince1970 < UserDefaults.standard.double(forKey: pairingUntilKey)
    }

    static var pairingSecondsLeft: Int {
        max(0, Int(UserDefaults.standard.double(forKey: pairingUntilKey) - Date().timeIntervalSince1970))
    }

    static func openPairing() {
        UserDefaults.standard.set(Date().timeIntervalSince1970 + pairingWindow, forKey: pairingUntilKey)
    }

    static func closePairing() {
        UserDefaults.standard.set(0, forKey: pairingUntilKey)
    }

    static var authFailures: Int {
        get { UserDefaults.standard.integer(forKey: failuresKey) }
        set { UserDefaults.standard.set(newValue, forKey: failuresKey) }
    }
}

extension Data {
    init?(garminHex hex: String) {
        guard hex.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index ..< next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }

    var garminHex: String { map { String(format: "%02x", $0) }.joined() }
}
