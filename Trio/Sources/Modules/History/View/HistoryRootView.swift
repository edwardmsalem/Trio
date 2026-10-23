import CoreData
import SwiftUI
import Swinject

extension History {
    struct RootView: BaseView {
        let resolver: Resolver
        /// Set by the wide-screen split view, whose sidebar picks the category. The segmented
        /// picker is then hidden. Nil on narrow screens, where the picker stays.
        var sidebarMode: Mode? = nil

        @State var state = StateModel()

        @State var deletionTarget: History.DeletionTarget?
        @State var showErrorAlert: Bool = false
        @State var errorMessage: String = ""
        @State var showFutureEntries: Bool = false // default to hide future entries
        @State var showManualGlucose: Bool = false
        @State var isAmountUnconfirmed: Bool = true
        @State var showTreatmentTypeFilter = false
        @State var selectedTreatmentTypes: Set<TreatmentType> = Set(TreatmentType.allCases)

        @Environment(\.colorScheme) var colorScheme
        @Environment(\.managedObjectContext) var context
        @Environment(AppState.self) var appState

        @FetchRequest(
            entity: GlucoseStored.entity(),
            sortDescriptors: [NSSortDescriptor(keyPath: \GlucoseStored.date, ascending: false)],
            predicate: NSPredicate.predicateForOneDayAgo,
            animation: .bouncy
        ) var glucoseStored: FetchedResults<GlucoseStored>

        @FetchRequest(
            entity: PumpEventStored.entity(),
            sortDescriptors: [NSSortDescriptor(keyPath: \PumpEventStored.timestamp, ascending: false)],
            predicate: NSPredicate.pumpHistoryLast24h,
            animation: .bouncy
        ) var pumpEventStored: FetchedResults<PumpEventStored>

        @FetchRequest(
            entity: CarbEntryStored.entity(),
            sortDescriptors: [NSSortDescriptor(keyPath: \CarbEntryStored.date, ascending: false)],
            predicate: NSPredicate.carbsHistory,
            animation: .bouncy
        ) var carbEntryStored: FetchedResults<CarbEntryStored>

        @FetchRequest(
            entity: OverrideRunStored.entity(),
            sortDescriptors: [NSSortDescriptor(keyPath: \OverrideRunStored.startDate, ascending: false)],
            predicate: NSPredicate.overridesRunStoredFromOneDayAgo,
            animation: .bouncy
        ) var overrideRunStored: FetchedResults<OverrideRunStored>

        @FetchRequest(
            entity: TempTargetRunStored.entity(),
            sortDescriptors: [NSSortDescriptor(keyPath: \TempTargetRunStored.startDate, ascending: false)],
            predicate: NSPredicate.tempTargetRunStoredFromOneDayAgo,
            animation: .bouncy
        ) var tempTargetRunStored: FetchedResults<TempTargetRunStored>

        var body: some View {
            historyConfirmations(
                ZStack(alignment: .center, content: {
                    VStack {
                        if sidebarMode == nil {
                            Picker("Mode", selection: $state.mode) {
                                ForEach(
                                    Mode.allCases.indexed(),
                                    id: \.1
                                ) { index, item in
                                    Text(item.name).tag(index)
                                }
                            }
                            .pickerStyle(SegmentedPickerStyle())
                            .padding(.horizontal)
                        }

                        Form {
                            switch state.mode {
                            case .treatments: treatmentsList
                            case .glucose: glucoseList
                            case .meals: mealsList
                            case .adjustments: adjustmentsList
                            }
                        }.scrollContentBackground(.hidden)
                            .background(appState.trioBackgroundColor(for: colorScheme))
                    }.blur(radius: state.waitForSuggestion ? 8 : 0)

                    // Show custom progress view
                    /// don't show it if glucose is stale as it will block the UI
                    if state.waitForSuggestion && state.isGlucoseDataFresh(glucoseStored.first?.date) {
                        CustomProgressView(text: progressText.displayName)
                    }
                })
                    .background(appState.trioBackgroundColor(for: colorScheme))
                    .onAppear(perform: configureView)
                    .onChange(of: sidebarMode, initial: true) { _, mode in
                        if let mode { state.mode = mode }
                    }
                    .onDisappear {
                        state.carbEntryDeleted = false
                        state.insulinEntryDeleted = false
                    }
                    .navigationTitle("History")
                    .navigationBarTitleDisplayMode(.large)
                    .toolbar {
                        // fallback pathway: the home panel's stats face can be
                        // displaced by higher-priority states
                        ToolbarItem(placement: .topBarLeading, content: {
                            Button(
                                action: { state.showModal(for: .statistics) },
                                label: {
                                    HStack {
                                        Image(systemName: "chart.bar.xaxis")
                                            .font(.title2)
                                        Text("Statistics")
                                    }
                                }
                            )
                        })
                        ToolbarItem(placement: .topBarTrailing, content: {
                            addButton({
                                showManualGlucose = true
                                state.manualGlucose = 0
                            })
                        })
                    }
                    .sheet(isPresented: $showManualGlucose) {
                        addGlucoseView()
                    }
                    .sheet(isPresented: $state.showCarbEntryEditor) {
                        if let carbEntry = state.carbEntryToEdit {
                            CarbEntryEditorView(state: state, carbEntry: carbEntry)
                        }
                    }
            )
        }

        @ViewBuilder func addButton(_ action: @escaping () -> Void) -> some View {
            Button(
                action: action,
                label: {
                    HStack {
                        Text("Add Glucose")
                        Image(systemName: "plus")
                            .font(.title2)
                    }
                }
            )
        }

        var progressText: ProgressText {
            switch (state.carbEntryDeleted, state.insulinEntryDeleted) {
            case (true, false):
                return .updatingCOB
            case(false, true):
                return .updatingIOB
            default:
                return .updatingHistory
            }
        }
    }

    /// History on a wide screen: the four categories in a sidebar beside the existing entry list.
    /// Uses the same History screen, so rows, filters, sheets and deletions are unchanged.
    struct SplitRootView<TreatmentItem: View>: View {
        let resolver: Resolver
        @ViewBuilder var treatmentItem: TreatmentItem

        @State private var mode: Mode? = .treatments
        @Environment(\.colorScheme) private var colorScheme
        @Environment(AppState.self) private var appState

        var body: some View {
            NavigationSplitView {
                List(Mode.allCases, selection: $mode) { item in
                    Text(item.name).tag(item)
                }
                .scrollContentBackground(.hidden)
                .background(appState.trioBackgroundColor(for: colorScheme))
                .navigationTitle("History")
                .treatmentToolbarItem(isEnabled: true) { treatmentItem }
            } detail: {
                NavigationStack {
                    RootView(resolver: resolver, sidebarMode: mode ?? .treatments)
                        .navigationTitle(mode?.name ?? String(localized: "History"))
                }
            }
        }
    }
}
