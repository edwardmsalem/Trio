import Foundation
import LoopKit

/// A complete, restorable snapshot of a Trio configuration. Unlike the CSV export
/// (a human-readable report), this is machine-readable JSON the app can load back
/// on another device.
struct SettingsBackup: Codable {
    var version: Int = 1
    var exportedAt: Date
    var appVersion: String?

    var settings: TrioSettings
    var preferences: Preferences
    var pumpSettings: PumpSettings
    var basalProfile: [BasalProfileEntry]
    var insulinSensitivities: InsulinSensitivities?
    var carbRatios: CarbRatios?
    var bgTargets: BGTargets?
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
            bgTargets: storage.retrieve(OpenAPS.Settings.bgTargets, as: BGTargets.self)
        )
    }

    /// Writes the backup to a temp `.json` file and returns its URL (for ShareLink).
    static func write(_ backup: SettingsBackup) throws -> URL {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(backup)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let name = "TrioBackup_\(formatter.string(from: Date())).json"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    static func decode(from url: URL) throws -> SettingsBackup {
        let needsStop = url.startAccessingSecurityScopedResource()
        defer { if needsStop { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(SettingsBackup.self, from: data)
    }

    struct ApplyOptions {
        var includeAppSettings = true
        var includeTherapy = true // ISF / CR / targets
        var includeBasal = true
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
