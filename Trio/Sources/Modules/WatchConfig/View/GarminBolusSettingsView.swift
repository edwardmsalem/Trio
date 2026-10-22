import SwiftUI
import Swinject

/// Settings for bolusing from the Garmin Bolus watch app. Layout follows Trio
/// Companion for Garmin's screen (github.com/k9track/trio-garmin-companion, MIT).
struct GarminBolusSettingsView: View {
    @AppStorage(GarminBolusSettings.enabledKey) private var isEnabled = false
    @AppStorage(GarminBolusSettings.maxCarbsKey) private var maxCarbs = GarminBolusSettings.defaultMaxCarbs

    @State private var pin = ""
    @State private var hasPIN = false
    @State private var isPaired = false
    @State private var pairingSeconds = 0
    @State private var failures = 0

    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    @Environment(\.colorScheme) var colorScheme
    @Environment(AppState.self) var appState

    private var pumpMaxBolus: Decimal? { TrioApp.resolver.resolve(SettingsManager.self)?.pumpSettings.maxBolus }

    var body: some View {
        Form {
            Section(
                header: Text("Watch Bolus"),
                footer: Text(
                    "Lets the paired Bolus app on your Garmin watch ask Trio for a bolus and log carbs. Trio works the dose out with its own bolus calculator and you confirm on the watch. Your Max Bolus, Max IOB, Max Carbs and the recent-bolus check apply exactly as on the phone, and you get a notification for every watch bolus."
                )
            ) {
                Toggle("Allow Bolus from Garmin", isOn: Binding(
                    get: { isEnabled },
                    set: { on in
                        isEnabled = on && isPaired
                        if on { GarminBolusSettings.authFailures = 0 }
                        refresh()
                    }
                ))
                    .disabled(!isPaired && !isEnabled)
                if !isPaired {
                    Text("Pair your watch first.").font(.footnote).foregroundColor(.secondary)
                } else if failures >= GarminBolusSettings.maxAuthFailures {
                    Text("Turned off after \(failures) requests with a wrong PIN or key.")
                        .font(.footnote).foregroundColor(.red)
                }
            }.listRowBackground(Color.chart)

            Section(header: Text("Watch Limits"), footer: Text(pumpMaxBolusFooter)) {
                Stepper(value: $maxCarbs, in: 5 ... 200, step: 5) {
                    HStack {
                        Text("Max carbs per watch entry")
                        Spacer()
                        Text("\(maxCarbs, specifier: "%.0f") g").foregroundColor(.secondary)
                    }
                }
            }.listRowBackground(Color.chart)

            Section(
                header: Text("PIN"),
                footer: Text("4 digits, used once to pair the watch. Kept on this iPhone and not synced to iCloud.")
            ) {
                SecureField(hasPIN ? "PIN saved, enter to change" : "Enter PIN", text: $pin)
                    .keyboardType(.numberPad)
                Button("Save PIN") { savePIN() }
                    .disabled(!GarminBolusSettings.isValidPIN(pin))
                if hasPIN {
                    Button("Remove PIN", role: .destructive) {
                        GarminBolusSettings.pin = nil
                        GarminBolusSettings.closePairing()
                        refresh()
                    }
                }
            }.listRowBackground(Color.chart)

            Section(
                header: Text("Pairing"),
                footer: Text(
                    "Tap Pair Watch, then open the Bolus app on the watch, choose Pair with Trio and enter the PIN within 2 minutes. Trio then gives the watch its own random key, and the PIN is never sent again."
                )
            ) {
                HStack {
                    Text("Status")
                    Spacer()
                    Text(isPaired ? "Paired" : pairingSeconds > 0 ? "Waiting for watch, \(pairingSeconds) s" : "Not paired")
                        .foregroundColor(isPaired ? .green : .secondary)
                }
                if pairingSeconds > 0 {
                    Button("Cancel Pairing") {
                        GarminBolusSettings.closePairing()
                        refresh()
                    }
                } else {
                    Button(isPaired ? "Pair Again" : "Pair Watch") {
                        GarminBolusSettings.openPairing()
                        refresh()
                    }
                    .disabled(!hasPIN)
                }
                if isPaired {
                    Button("Unpair Watch", role: .destructive) {
                        GarminBolusSettings.unpair()
                        refresh()
                    }
                }
            }.listRowBackground(Color.chart)
        }
        .scrollContentBackground(.hidden)
        .background(appState.trioBackgroundColor(for: colorScheme))
        .navigationTitle("Garmin Watch Bolus")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { refresh() }
        .onReceive(tick) { _ in refresh() }
    }

    private var pumpMaxBolusFooter: String {
        let base = String(
            localized: "Watch boluses are capped by your pump's Max Bolus, the same as the phone. Carbs from the watch are also capped here, below Trio's Max Carbs."
        )
        guard let pumpMaxBolus else { return base }
        return base + " " +
            String(localized: "Pump Max Bolus: \(NSDecimalNumber(decimal: pumpMaxBolus).doubleValue, specifier: "%.1f") U.")
    }

    private func refresh() {
        hasPIN = GarminBolusSettings.pin != nil
        isPaired = GarminBolusSettings.isPaired
        pairingSeconds = GarminBolusSettings.pairingSecondsLeft
        failures = GarminBolusSettings.authFailures
        if !isPaired, isEnabled { isEnabled = false }
    }

    private func savePIN() {
        guard GarminBolusSettings.isValidPIN(pin) else { return }
        GarminBolusSettings.pin = pin
        pin = ""
        refresh()
    }
}
