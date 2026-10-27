import SwiftUI
import Swinject

extension AAPSDosing {
    struct RootView: BaseView {
        let resolver: Resolver
        @State var state = StateModel()

        @Environment(\.colorScheme) var colorScheme
        @Environment(AppState.self) var appState

        var body: some View {
            List {
                Section(
                    footer: Text(
                        "On: the loop doses with the same calculation as AndroidAPS SMB, including AAPS Dynamic ISF, its separate dosing sensitivity and the ISF tiers. Off: stock Trio dosing. Your SMB, target, max IOB and max basal settings apply either way."
                    )
                ) {
                    Toggle("AAPS Dosing", isOn: $state.enabled)
                }
                .listRowBackground(Color.chart)

                if state.enabled {
                    Section(
                        header: Text("Dynamic ISF (AAPS)"),
                        footer: Text(
                            "Sensitivity follows BG and a blend of the last 8 hours, yesterday and the 7-day average TDD. Until Trio has 7 full days of insulin history, the starting TDD stands in for each missing day, and real days replace it one by one. At 0 U it waits the full week on profile ISF. Adjust sensitivity sets the autosens ratio from last-24h versus 7-day insulin and carbs."
                        )
                    ) {
                        Toggle("Dynamic ISF", isOn: $state.dynamicISF)
                        if state.dynamicISF {
                            Stepper(
                                "Adjustment factor: \(state.adjustmentFactorPercent)%",
                                value: $state.adjustmentFactorPercent,
                                in: AAPSDosingSettings.adjustmentFactorRange,
                                step: 5
                            )
                            Stepper(
                                "Starting TDD: \(state.startingTDD) U",
                                value: $state.startingTDD,
                                in: AAPSDosingSettings.startingTDDRange,
                                step: 1
                            )
                            Toggle("Adjust sensitivity from TDD", isOn: $state.adjustSensitivityFromTDD)
                        }
                    }
                    .listRowBackground(Color.chart)

                    Section(
                        header: Text("ISF Tiers"),
                        footer: Text(
                            "Uses your ISF Tiers settings. On top of dynamic multiplies the dynamic ISF by the tier, as AAPS does. Trio order tiers the profile ISF first, where the dynamic formula mostly cancels it. The carb ratio tier always applies with tiers here, as in AAPS."
                        )
                    ) {
                        Picker("Tier order", selection: $state.tierOrder) {
                            Text("On top of dynamic").tag(AAPSTierOrder.onTopOfDynamic)
                            Text("Trio order").tag(AAPSTierOrder.trioOrder)
                        }
                    }
                    .listRowBackground(Color.chart)

                    Section(
                        header: Text("Low Glucose Guard"),
                        footer: Text(
                            "Trio saves fat and protein as carb entries dated in the next few hours. On: the low glucose guard counts the ones due in the next 4 hours, so food you already entered does not stop insulin for a low that will not come. It never adds insulin for that food, and it does not change COB, eventual BG or your safety limits. Off: the guard sees only carbs dated now or earlier, as AAPS does."
                        )
                    ) {
                        Toggle("Guard sees upcoming fat/protein", isOn: $state.guardSeesUpcomingCarbs)
                    }
                    .listRowBackground(Color.chart)
                }
            }
            .listSectionSpacing(sectionSpacing)
            .scrollContentBackground(.hidden)
            .background(appState.trioBackgroundColor(for: colorScheme))
            .onAppear(perform: configureView)
            .navigationBarTitle("AAPS Dosing")
            .navigationBarTitleDisplayMode(.automatic)
        }
    }
}
