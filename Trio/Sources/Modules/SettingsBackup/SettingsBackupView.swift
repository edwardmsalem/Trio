import SwiftUI
import Swinject

/// Backup & Restore: export a complete settings file from one device and import it
/// on another. Importing therapy/dosing settings is gated behind a clear confirm
/// step. This screen never doses; basal is pushed through the pump's own sync.
struct SettingsBackupView: View {
    let resolver: Resolver

    @Environment(\.dismiss) private var dismiss

    @State private var exportURL: URL?
    @State private var exportError: String?

    @State private var showImporter = false
    @State private var pendingBackup: SettingsBackup?
    @State private var importError: String?

    // What the user chose to apply.
    @State private var applyAppSettings = true
    @State private var applyTherapy = true
    @State private var applyBasal = true

    @State private var isApplying = false
    @State private var resultMessage: String?
    @State private var showResult = false

    private var storage: FileStorage? { resolver.resolve(FileStorage.self) }
    private var settingsManager: SettingsManager? { resolver.resolve(SettingsManager.self) }

    var body: some View {
        NavigationStack {
            List {
                exportSection
                importSection
            }
            .navigationTitle("Backup & Restore")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .fileImporter(
                isPresented: $showImporter,
                allowedContentTypes: [.json],
                allowsMultipleSelection: false
            ) { result in
                handleImportResult(result)
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
            Text("Export")
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
                } header: {
                    Text("Apply")
                } footer: {
                    Text(
                        "Therapy profiles and basal rates control how Trio doses insulin. Only restore them onto a device meant to run the same therapy. Basal rates are pushed to your pump and need it connected."
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
                    .disabled(isApplying || (!applyAppSettings && !applyTherapy && !applyBasal))
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
            includeBasal: applyBasal
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
            lines.append(String(localized: "Applied:"))
            lines.append(contentsOf: result.applied.map { "• \($0)" })
        }
        if !result.warnings.isEmpty {
            lines.append("")
            lines.append(contentsOf: result.warnings.map { "⚠️ \($0)" })
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
