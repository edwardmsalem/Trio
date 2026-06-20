import SwiftUI
import Swinject

extension ISFTiersEditor {
    struct RootView: BaseView {
        let resolver: Resolver
        @State var state = StateModel()

        @Environment(\.colorScheme) var colorScheme
        @Environment(AppState.self) var appState

        var body: some View {
            List {
                Section(
                    header: Text("ISF Sensitivity Tiers"),
                    footer: Text(
                        "When enabled, your profile ISF is multiplied by the tier value matching your current BG. A multiplier below 100% makes corrections more aggressive (lower ISF); above 100% makes them less aggressive."
                    )
                ) {
                    Toggle("Enable ISF Tiers", isOn: $state.enabled)
                }
                .listRowBackground(Color.chart)

                if state.enabled {
                    Section(
                        header: Text("BG Range Tiers"),
                        footer: Text(
                            "Define BG ranges and the ISF multiplier for each. Ranges are in \(state.units == .mmolL ? "mmol/L" : "mg/dL"). Multiplier 100% = no change, 80% = more aggressive, 120% = less aggressive."
                        )
                    ) {
                        ForEach(Array(state.tiers.enumerated()), id: \.element.id) { index, tier in
                            ISFTierRow(
                                tier: Binding(
                                    get: { state.tiers[index] },
                                    set: { state.tiers[index] = $0 }
                                ),
                                units: state.units,
                                showCarbEffect: state.carbTierEnabled,
                                carbAggression: state.carbAggression(for: state.tiers[index].isfMultiplier)
                            )
                        }
                        .onDelete { offsets in
                            state.removeTier(at: offsets)
                        }

                        if state.canAddTier {
                            Button(action: state.addTier) {
                                HStack {
                                    Image(systemName: "plus.circle.fill")
                                        .foregroundColor(.green)
                                    Text("Add Tier")
                                }
                            }
                        }
                    }
                    .listRowBackground(Color.chart)

                    Section(
                        header: Text("Carb Ratio Tiering"),
                        footer: Text(
                            "When on, your carb ratio is also tightened at high BG so meals eaten while high get more insulin. It is DAMPED (about half the ISF aggressiveness, capped at +30%) and never applies below 140 mg/dL. Flagged fatty meals are excluded. Off by default — verify your max-IOB and watch 2–3h post-meal lows before trusting it."
                        )
                    ) {
                        Toggle("Also tighten carb ratio at high BG", isOn: $state.carbTierEnabled)
                    }
                    .listRowBackground(Color.chart)
                }

                if state.hasChanges {
                    Section {
                        Button(action: state.save) {
                            if state.shouldDisplaySaving {
                                ProgressView()
                                    .frame(maxWidth: .infinity, alignment: .center)
                            } else {
                                Text("Save")
                                    .frame(maxWidth: .infinity, alignment: .center)
                                    .font(.headline)
                            }
                        }
                        .disabled(state.shouldDisplaySaving)
                    }
                    .listRowBackground(Color.chart)
                }
            }
            .listSectionSpacing(sectionSpacing)
            .scrollContentBackground(.hidden)
            .background(appState.trioBackgroundColor(for: colorScheme))
            .onAppear(perform: configureView)
            .navigationBarTitle("ISF Tiers")
            .navigationBarTitleDisplayMode(.automatic)
        }
    }
}

private struct ISFTierRow: View {
    @Binding var tier: InsulinSensitivityTier
    let units: GlucoseUnits
    var showCarbEffect: Bool = false
    var carbAggression: Decimal = 1

    @State private var showingEditor = false

    /// Whether this band actually moves the carb ratio (aggressive ISF + above the
    /// BG-140 floor). Bands below 140 are never carb-tiered.
    private var carbEffectActive: Bool {
        showCarbEffect && tier.isfMultiplier < 1 && carbAggression > 1 && tier.bgMax > InsulinSensitivityTiers.carbTierBGFloor
    }

    private var carbEffectText: String {
        // carbAggression is the divisor; insulin-per-carb increase is (aggr - 1).
        let pct = Int(truncating: ((carbAggression - 1) * 100) as NSDecimalNumber)
        return "Carbs: +\(pct)% insulin (damped)"
    }

    private func displayBG(_ value: Decimal) -> String {
        if units == .mmolL {
            return "\(value.asMmolL)"
        }
        return "\(value)"
    }

    private var unitsLabel: String {
        units.rawValue
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: { showingEditor.toggle() }) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("BG \(displayBG(tier.bgMin)) - \(displayBG(tier.bgMax)) \(unitsLabel)")
                            .font(.subheadline)
                            .foregroundColor(.primary)
                        Text("ISF multiplier: \(Int(truncating: (tier.isfMultiplier * 100) as NSDecimalNumber))%")
                            .font(.caption)
                            .foregroundColor(multiplierColor)
                        if carbEffectActive {
                            Text(carbEffectText)
                                .font(.caption2)
                                .foregroundColor(.purple)
                        }
                    }
                    Spacer()
                    Image(systemName: showingEditor ? "chevron.up" : "chevron.down")
                        .foregroundColor(.secondary)
                        .font(.caption)
                }
            }
            .buttonStyle(.plain)

            if showingEditor {
                VStack(spacing: 12) {
                    HStack {
                        Text("BG Min")
                            .frame(width: 60, alignment: .leading)
                        Stepper(
                            value: $tier.bgMin,
                            in: 0 ... max(tier.bgMax - 1, 1),
                            step: units == .mmolL ? 18 : 10
                        ) {
                            Text("\(displayBG(tier.bgMin)) \(unitsLabel)")
                                .monospacedDigit()
                        }
                    }

                    HStack {
                        Text("BG Max")
                            .frame(width: 60, alignment: .leading)
                        Stepper(
                            value: $tier.bgMax,
                            in: (tier.bgMin + 1) ... 400,
                            step: units == .mmolL ? 18 : 10
                        ) {
                            Text("\(displayBG(tier.bgMax)) \(unitsLabel)")
                                .monospacedDigit()
                        }
                    }

                    HStack {
                        Text("ISF %")
                            .frame(width: 60, alignment: .leading)
                        Stepper(
                            value: $tier.isfMultiplier,
                            in: 0.5 ... 1.5,
                            step: 0.05
                        ) {
                            Text("\(Int(truncating: (tier.isfMultiplier * 100) as NSDecimalNumber))%")
                                .monospacedDigit()
                                .foregroundColor(multiplierColor)
                        }
                    }
                }
                .padding(.top, 4)
                .font(.subheadline)
            }
        }
        .padding(.vertical, 4)
    }

    private var multiplierColor: Color {
        if tier.isfMultiplier < 1.0 {
            return .orange // more aggressive
        } else if tier.isfMultiplier > 1.0 {
            return .blue // less aggressive
        }
        return .secondary // no change
    }
}
