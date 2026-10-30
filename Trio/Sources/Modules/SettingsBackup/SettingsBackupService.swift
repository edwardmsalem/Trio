import Foundation
import LoopKit

/// A complete, restorable snapshot of a Trio configuration. Unlike the CSV export
/// (a human-readable report), this is machine-readable JSON the app can load back
/// on another device.
struct SettingsBackup: Codable {
    var version: Int = 2
    var exportedAt: Date
    var appVersion: String?

    var settings: TrioSettings
    var preferences: Preferences
    var pumpSettings: PumpSettings
    var basalProfile: [BasalProfileEntry]
    var insulinSensitivities: InsulinSensitivities?
    var carbRatios: CarbRatios?
    var bgTargets: BGTargets?
    // Added in version 2. Optional so version 1 files still load.
    var aapsDosing: AAPSDosingSettings?
    var isfTiers: InsulinSensitivityTiers?
}

/// Builds, writes, reads, and applies `SettingsBackup` files. Applying therapy and
/// basal settings changes dosing, so callers must gate `apply` behind explicit user
/// confirmation. Nothing here doses directly — basal goes through the pump's own
/// `syncBasalRateSchedule`, exactly like the in-app basal editor.
enum SettingsBackupService {
    static func makeBackup(storage: FileStorage, settingsManager: SettingsManager) -> SettingsBackup {
        SettingsBackup(
            exportedAt: Date(),
            appVersion: Bundle.main.appDevVersion,
            settings: settingsManager.settings,
            preferences: settingsManager.preferences,
            pumpSettings: settingsManager.pumpSettings,
            basalProfile: storage.retrieve(OpenAPS.Settings.basalProfile, as: [BasalProfileEntry].self) ?? [],
            insulinSensitivities: storage.retrieve(OpenAPS.Settings.insulinSensitivities, as: InsulinSensitivities.self),
            carbRatios: storage.retrieve(OpenAPS.Settings.carbRatios, as: CarbRatios.self),
            bgTargets: storage.retrieve(OpenAPS.Settings.bgTargets, as: BGTargets.self),
            aapsDosing: storage.retrieve(OpenAPS.Settings.aapsDosing, as: AAPSDosingSettings.self),
            isfTiers: storage.retrieve(OpenAPS.Settings.insulinSensitivityTiers, as: InsulinSensitivityTiers.self)
        )
    }

    /// Writes the backup to a temp `.json` file and returns its URL (for ShareLink).
    static func write(_ backup: SettingsBackup) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName())
        try encode(backup).write(to: url)
        return url
    }

    private static func encode(_ backup: SettingsBackup) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(backup)
    }

    /// `TrioBackup_yyyyMMdd_HHmmss.json`, so names sort oldest to newest.
    private static func fileName() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return "TrioBackup_\(formatter.string(from: Date())).json"
    }

    // MARK: - Backup folder

    /// The folder Create Backup saves into, picked once (for example iCloud Drive) and
    /// remembered as a bookmark. Backups go in a "Trio" subfolder unless the picked
    /// folder is already called Trio.
    enum Folder {
        private static let bookmarkKey = "settingsBackup.folderBookmark"

        enum FolderError: LocalizedError {
            case notChosen
            case noAccess
            case noBackups

            var errorDescription: String? {
                switch self {
                case .notChosen: return String(localized: "Choose a backup folder first.")
                case .noAccess: return String(localized: "Trio lost access to the backup folder. Choose it again.")
                case .noBackups: return String(localized: "No Trio backups found in the backup folder.")
                }
            }
        }

        /// Remembers a folder the user picked in the document picker.
        static func choose(_ url: URL) throws {
            let needsStop = url.startAccessingSecurityScopedResource()
            defer { if needsStop { url.stopAccessingSecurityScopedResource() } }
            let bookmark = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            UserDefaults.standard.set(bookmark, forKey: bookmarkKey)
        }

        /// The picked folder, or nil if none was chosen yet.
        static func chosen() -> URL? {
            guard let bookmark = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
            var isStale = false
            guard let url = try? URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &isStale)
            else { return nil }
            if isStale { try? choose(url) }
            return url
        }

        /// Where the files go, shown to the user, for example "iCloud Drive › Trio".
        static func displayName(for url: URL) -> String {
            let parent = url.lastPathComponent
            return parent == "Trio" ? parent : "\(parent) › Trio"
        }

        /// Writes the backup into the folder and returns the new file's name.
        static func save(_ backup: SettingsBackup) async throws -> String {
            guard let root = chosen() else { throw FolderError.notChosen }
            let data = try encode(backup)
            let name = fileName()
            try await Task.detached { () throws in
                try withAccess(to: root) { folder -> Void in
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    try coordinate(writing: folder.appendingPathComponent(name)) { try data.write(to: $0, options: .atomic) }
                }
            }.value
            return name
        }

        /// Reads the newest backup in the folder, downloading it from iCloud first if needed.
        static func loadLatest() async throws -> SettingsBackup {
            guard let root = chosen() else { throw FolderError.notChosen }
            return try await Task.detached { () throws -> SettingsBackup in
                try withAccess(to: root) { folder -> SettingsBackup in
                    let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
                    // A file iCloud has not downloaded yet is listed as ".Name.json.icloud".
                    let backups = names.compactMap { name -> String? in
                        var real = name
                        if real.hasPrefix("."), real.hasSuffix(".icloud") {
                            real = String(real.dropFirst().dropLast(".icloud".count))
                        }
                        return real.hasPrefix("TrioBackup_") && real.hasSuffix(".json") ? real : nil
                    }
                    guard let newest = Set(backups).max() else { throw FolderError.noBackups }
                    let url = folder.appendingPathComponent(newest)
                    try? FileManager.default.startDownloadingUbiquitousItem(at: url)
                    var data = Data()
                    try coordinate(reading: url) { data = try Data(contentsOf: $0) }
                    return try JSONDecoder().decode(SettingsBackup.self, from: data)
                }
            }.value
        }

        private static func withAccess<T>(to root: URL, _ body: (URL) throws -> T) throws -> T {
            guard root.startAccessingSecurityScopedResource() else { throw FolderError.noAccess }
            defer { root.stopAccessingSecurityScopedResource() }
            let folder = root.lastPathComponent == "Trio" ? root : root.appendingPathComponent("Trio", isDirectory: true)
            return try body(folder)
        }

        private static func coordinate(writing url: URL, _ body: (URL) throws -> Void) throws {
            var coordinatorError: NSError?
            var bodyError: Error?
            NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinatorError) { url in
                do { try body(url) } catch { bodyError = error }
            }
            if let error = coordinatorError ?? bodyError { throw error }
        }

        private static func coordinate(reading url: URL, _ body: (URL) throws -> Void) throws {
            var coordinatorError: NSError?
            var bodyError: Error?
            NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinatorError) { url in
                do { try body(url) } catch { bodyError = error }
            }
            if let error = coordinatorError ?? bodyError { throw error }
        }
    }

    static func decode(from url: URL) throws -> SettingsBackup {
        let needsStop = url.startAccessingSecurityScopedResource()
        defer { if needsStop { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(SettingsBackup.self, from: data)
    }

    /// The same limits the ISF tiers editor allows: multipliers 0.5 to 1.5, ranges inside
    /// 0 to 400 mg/dL with a positive width, and never more aggressive than 1.0 below 70.
    static func isfTiersAreSafe(_ tiers: InsulinSensitivityTiers) -> Bool {
        tiers.tiers.allSatisfy { tier in
            tier.isfMultiplier >= 0.5 && tier.isfMultiplier <= 1.5
                && tier.bgMin >= 0 && tier.bgMax <= 400 && tier.bgMin < tier.bgMax
                && (tier.bgMin >= 70 || tier.isfMultiplier >= 1)
        }
    }

    struct ApplyOptions {
        var includeAppSettings = true
        var includeTherapy = true // ISF / CR / targets
        var includeBasal = true
        var includeAAPSDosing = true // AAPS dosing mode settings and ISF tiers
    }

    struct ApplyResult {
        var applied: [String] = []
        var warnings: [String] = []
    }

    /// Applies a backup. App settings + algorithm preferences + ISF/CR/targets are
    /// written to storage and take effect on the next loop. Basal is synced to the
    /// pump first (and only saved if the sync succeeds); with no pump connected it
    /// is skipped with a warning so storage never disagrees with the pump.
    @MainActor static func apply(
        _ backup: SettingsBackup,
        options: ApplyOptions,
        settingsManager: SettingsManager,
        storage: FileStorage,
        pumpManager: PumpManager?
    ) async -> ApplyResult {
        var result = ApplyResult()

        if options.includeAppSettings {
            settingsManager.settings = backup.settings
            settingsManager.preferences = backup.preferences
            storage.save(backup.pumpSettings, as: OpenAPS.Settings.settings)
            result.applied.append(String(localized: "App settings, algorithm preferences, and pump limits"))
        }

        if options.includeTherapy {
            if let isf = backup.insulinSensitivities {
                storage.save(isf, as: OpenAPS.Settings.insulinSensitivities)
            }
            if let cr = backup.carbRatios {
                storage.save(cr, as: OpenAPS.Settings.carbRatios)
            }
            if let targets = backup.bgTargets {
                storage.save(targets, as: OpenAPS.Settings.bgTargets)
            }
            result.applied.append(String(localized: "Insulin sensitivity, carb ratio, and target profiles"))
        }

        if options.includeAAPSDosing, backup.aapsDosing != nil || backup.isfTiers != nil {
            if let aapsDosing = backup.aapsDosing {
                storage.save(aapsDosing, as: OpenAPS.Settings.aapsDosing)
            }
            if let tiers = backup.isfTiers {
                if isfTiersAreSafe(tiers) {
                    storage.save(tiers, as: OpenAPS.Settings.insulinSensitivityTiers)
                    result.applied.append(String(localized: "ISF tiers"))
                } else {
                    result.warnings.append(String(
                        localized: "The ISF tiers in this backup are outside the allowed limits, so your current tiers were kept."
                    ))
                }
            }
            if backup.aapsDosing != nil {
                // Decoding already clamped the adjustment factor and starting TDD to their ranges.
                result.applied.append(String(localized: "AAPS dosing settings"))
            }
        }

        if options.includeBasal, !backup.basalProfile.isEmpty {
            if let pump = pumpManager {
                let syncValues = backup.basalProfile.map {
                    RepeatingScheduleValue(startTime: TimeInterval($0.minutes * 60), value: Double($0.rate))
                }
                let synced = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                    pump.syncBasalRateSchedule(items: syncValues) { syncResult in
                        switch syncResult {
                        case .success: continuation.resume(returning: true)
                        case .failure: continuation.resume(returning: false)
                        }
                    }
                }
                if synced {
                    storage.save(backup.basalProfile, as: OpenAPS.Settings.basalProfile)
                    result.applied.append(String(localized: "Basal rate schedule (synced to pump)"))
                } else {
                    result.warnings.append(String(
                        localized: "Basal rates couldn't be synced to your pump. Open Therapy → Basal Rates to apply them manually."
                    ))
                }
            } else {
                result.warnings.append(String(
                    localized: "No pump is connected, so basal rates were not changed. Connect your pump, then open Therapy → Basal Rates to apply them."
                ))
            }
        }

        return result
    }
}
