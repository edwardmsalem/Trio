import SwiftUI
import Swinject

/// Backup & Restore: export a complete settings file from one device and import it
/// on another. Importing therapy/dosing settings is gated behind a clear confirm
/// step. This screen never doses; basal is pushed through the pump's own sync.
struct SettingsBackupView: View {
    let resolver: Resolver

    @State private var exportURL: URL?
    @State private var exportError: String?

    @State private var showImporter = false
    @State private var showFolderPicker = false
    @State private var folderURL = SettingsBackupService.Folder.chosen()
    @State private var folderStatus: String?
    @State private var isSavingToFolder = false
    @State private var isLoadingLatest = false
    @State private var pendingBackup: SettingsBackup?
    @State private var importError: String?

    // What the user chose to apply.
    @State private var applyAppSettings = true
    @State private var applyTherapy = true
    @State private var applyBasal = true
    @State private var applyAAPSDosing = true

    @State private var isApplying = false
    @State private var resultMessage: String?
    @State private var showResult = false

    private var storage: FileStorage? { resolver.resolve(FileStorage.self) }
    private var settingsManager: SettingsManager? { resolver.resolve(SettingsManager.self) }

    var body: some View {
        // This screen is PUSHED onto the Settings navigation stack, so it must not
        // wrap itself in another NavigationStack — nested NavigationStacks render as
        // a blank screen (with a warning triangle) on iOS 26. The parent provides
        // the "Back" button.
        List {
            folderSection
            exportSection
            importSection
        }
        .navigationTitle("Backup & Restore")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            handleImportResult(result)
        }
        .background {
            // A second file picker needs its own view; two on one view clash.
            Color.clear.fileImporter(
                isPresented: $showFolderPicker,
                allowedContentTypes: [.folder],
                allowsMultipleSelection: false
            ) { result in
                handleFolderResult(result)
            }
        }
        .sheet(item: $pendingBackup) { backup in
            confirmSheet(for: backup)
        }
        .alert("Import", isPresented: $showResult) {
            Button("OK") {}
        } message: {
            Text(resultMessage ?? "")
        }
    }

    // MARK: - Backup folder

    private var folderSection: some View {
        Section {
            if let folderURL {
                Button {
                    Task { await saveToFolder() }
                } label: {
                    if isSavingToFolder {
                        ProgressView()
                    } else {
                        Label("Create Backup", systemImage: "icloud.and.arrow.up")
                    }
                }
                .disabled(isSavingToFolder)
                Button {
                    Task { await restoreLatest() }
                } label: {
                    if isLoadingLatest {
                        ProgressView()
                    } else {
                        Label("Restore Latest Backup", systemImage: "icloud.and.arrow.down")
                    }
                }
                .disabled(isLoadingLatest)
                Button {
                    showFolderPicker = true
                } label: {
                    Label("Change Folder (\(SettingsBackupService.Folder.displayName(for: folderURL)))", systemImage: "folder")
                }
            } else {
                Button {
                    showFolderPicker = true
                } label: {
                    Label("Choose Backup Folder", systemImage: "folder.badge.plus")
                }
            }
            if let folderStatus {
                Text(folderStatus).font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("Backup Folder")
        } footer: {
            Text(
                "Pick iCloud Drive once on each phone. Create Backup saves into a Trio folder there, and Restore Latest Backup on your other phone loads the newest one. You'll review what changes before anything is applied."
            )
        }
    }

    // MARK: - Export

    private var exportSection: some View {
        Section {
            if let url = exportURL {
                ShareLink(item: url) {
                    Label("Share backup file", systemImage: "square.and.arrow.up")
                }
            }
            Button {
                makeExport()
            } label: {
                Label(exportURL == nil ? "Create Backup" : "Recreate Backup", systemImage: "doc.badge.plus")
            }
            if let exportError {
                Text(exportError).font(.caption).foregroundStyle(.red)
            }
        } header: {
            Text("Share a Backup File")
        } footer: {
            Text(
                "Creates a complete settings file (app preferences, alarms, presets, and therapy/dosing settings), then lets you AirDrop, message, or save it. Import it on your other device below."
            )
        }
    }

    // MARK: - Import

    private var importSection: some View {
        Section {
            Button {
                showImporter = true
            } label: {
                Label("Import Backup", systemImage: "square.and.arrow.down")
            }
            if let importError {
                Text(importError).font(.caption).foregroundStyle(.red)
            }
        } header: {
            Text("Restore")
        } footer: {
            Text(
                "Pick a backup file. You'll review exactly what will change — including a clear warning before any dosing settings are applied — before anything takes effect."
            )
        }
    }

    // MARK: - Confirm

    private func confirmSheet(for backup: SettingsBackup) -> some View {
        NavigationStack {
            List {
                Section {
                    Text(
                        "This backup was created \(backup.exportedAt.formatted(date: .abbreviated, time: .shortened))\(backup.appVersion.map { " on Trio \($0)" } ?? "")."
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }

                Section {
                    Toggle("App settings & alarms", isOn: $applyAppSettings)
                    Toggle("Therapy profiles (ISF, carb ratio, targets)", isOn: $applyTherapy)
                    Toggle("Basal rates", isOn: $applyBasal)
                    if backup.aapsDosing != nil || backup.isfTiers != nil {
                        Toggle("AAPS dosing settings & ISF tiers", isOn: $applyAAPSDosing)
                    }
                    if let tiers = backup.isfTiers, applyAAPSDosing {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(tiers.enabled ? "ISF tiers (on)" : "ISF tiers (off)")
                            ForEach(tiers.tiers) { tier in
                                Text("\(tier.bgMin.description)–\(tier.bgMax.description) mg/dL: × \(tier.isfMultiplier.description)")
                            }
                            if !SettingsBackupService.isfTiersAreSafe(tiers) {
                                Text("Outside the allowed limits. These tiers will not be applied.")
                                    .foregroundStyle(.red)
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Apply")
                } footer: {
                    Text(
                        "Therapy profiles, basal rates, and AAPS dosing settings control how Trio doses insulin. Only restore them onto a device meant to run the same therapy. Basal rates are pushed to your pump and need it connected."
                    )
                }

                Section {
                    Button(role: .destructive) {
                        Task { await applyBackup(backup) }
                    } label: {
                        if isApplying {
                            ProgressView()
                        } else {
                            Text("Apply Backup")
                        }
                    }
                    .disabled(isApplying || (!applyAppSettings && !applyTherapy && !applyBasal && !applyAAPSDosing))
                }
            }
            .navigationTitle("Review Restore")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { pendingBackup = nil }
                }
            }
        }
    }

    // MARK: - Actions

    private func makeExport() {
        guard let storage, let settingsManager else {
            exportError = String(localized: "Couldn't access settings.")
            return
        }
        do {
            let backup = SettingsBackupService.makeBackup(storage: storage, settingsManager: settingsManager)
            exportURL = try SettingsBackupService.write(backup)
            exportError = nil
        } catch {
            exportError = error.localizedDescription
        }
    }

    private func handleFolderResult(_ result: Result<[URL], Error>) {
        switch result {
        case let .success(urls):
            guard let url = urls.first else { return }
            do {
                try SettingsBackupService.Folder.choose(url)
                folderURL = SettingsBackupService.Folder.chosen()
                folderStatus = nil
            } catch {
                folderStatus = error.localizedDescription
            }
        case let .failure(error):
            folderStatus = error.localizedDescription
        }
    }

    private func saveToFolder() async {
        guard let storage, let settingsManager else {
            folderStatus = String(localized: "Couldn't access settings.")
            return
        }
        isSavingToFolder = true
        defer { isSavingToFolder = false }
        do {
            let backup = SettingsBackupService.makeBackup(storage: storage, settingsManager: settingsManager)
            let name = try await SettingsBackupService.Folder.save(backup)
            folderStatus = String(localized: "Saved \(name)")
        } catch {
            folderStatus = error.localizedDescription
        }
    }

    private func restoreLatest() async {
        isLoadingLatest = true
        defer { isLoadingLatest = false }
        do {
            pendingBackup = try await SettingsBackupService.Folder.loadLatest()
            folderStatus = nil
        } catch let error as SettingsBackupService.Folder.FolderError {
            folderStatus = error.localizedDescription
        } catch {
            folderStatus = String(localized: "The newest backup in the folder couldn't be read.")
        }
    }

    private func handleImportResult(_ result: Result<[URL], Error>) {
        importError = nil
        switch result {
        case let .success(urls):
            guard let url = urls.first else { return }
            do {
                pendingBackup = try SettingsBackupService.decode(from: url)
            } catch {
                importError = String(localized: "That file isn't a valid Trio backup.")
            }
        case let .failure(error):
            importError = error.localizedDescription
        }
    }

    private func applyBackup(_ backup: SettingsBackup) async {
        guard let storage, let settingsManager else { return }
        isApplying = true
        let options = SettingsBackupService.ApplyOptions(
            includeAppSettings: applyAppSettings,
            includeTherapy: applyTherapy,
            includeBasal: applyBasal,
            includeAAPSDosing: applyAAPSDosing
        )
        let pump = resolver.resolve(DeviceDataManager.self)?.pumpManager
        let result = await SettingsBackupService.apply(
            backup,
            options: options,
            settingsManager: settingsManager,
            storage: storage,
            pumpManager: pump
        )
        isApplying = false
        pendingBackup = nil

        var lines: [String] = []
        if !result.applied.isEmpty {
            lines.append(String(localized: "Restore complete. Applied:"))
            lines.append(contentsOf: result.applied.map { "• \($0)" })
        }
        if !result.warnings.isEmpty {
            lines.append("")
            // Framed as a next step, not an error — these are expected when the
            // pump isn't connected on a fresh phone.
            lines.append(String(localized: "Still to finish (not an error):"))
            lines.append(contentsOf: result.warnings.map { "• \($0)" })
        }
        if lines.isEmpty {
            lines.append(String(localized: "Nothing was applied."))
        }
        resultMessage = lines.joined(separator: "\n")
        showResult = true
    }
}

/// Lets `SettingsBackup` drive a `.sheet(item:)`.
extension SettingsBackup: Identifiable {
    var id: Date { exportedAt }
}
