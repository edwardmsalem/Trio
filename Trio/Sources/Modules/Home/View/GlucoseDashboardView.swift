import Charts
import SwiftUI

extension Home {
    /// Liquid Glass reskin of the home glucose dashboard (System Blue direction).
    ///
    /// Reads the live Home `StateModel` — current glucose, trend, eventual, IOB/COB,
    /// loop status, basal, reservoir, pod age, and the glucose history for the chart —
    /// and renders it in the glass language built in `TrioGlass`. This is a new file;
    /// `HomeRootView` swaps only its main-tab content to this view, so the surrounding
    /// machinery (sheets, tabs, the + button) and all of Trio's engines stay untouched.
    struct GlucoseDashboardView: View {
        let state: StateModel

        /// Pump/CGM model-pick dialogs live as @State on the RootView (they drive
        /// `.confirmationDialog`s attached around this view), so they're passed in as
        /// bindings. Everything else is wired straight through `state` (the StateModel).
        @Binding var showPumpSelection: Bool
        @Binding var showCGMSelection: Bool
        @Binding var selectedTab: Int

        private func haptic(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
            UIImpactFeedbackGenerator(style: style).impactOccurred()
        }

        // MARK: - Interaction wiring (mirrors the stock Home taps 1:1)

        /// Tap the glucose number → CGM setup, or the model picker if no CGM yet.
        private func tapGlucose() {
            if !state.cgmAvailable { showCGMSelection.toggle() }
            else { state.shouldDisplayCGMSetupSheet.toggle() }
        }

        /// Long-press the glucose number → snooze the alarm (same as stock).
        private func longPressGlucose() {
            haptic(.heavy)
            state.showModal(for: .snooze)
        }

        /// Tap the Pod card → pump settings, or the model picker if no pump yet.
        private func tapPump() {
            if state.pumpDisplayState == nil { showPumpSelection.toggle() }
            else { state.shouldDisplayPumpSetupSheet.toggle() }
        }

        // MARK: - Derived live data

        private var readings: [GlucoseStored] {
            state.glucoseFromPersistence.sorted { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }
        }

        private var currentValue: Int? { readings.last.map { Int($0.glucose) } }
        private var previousValue: Int? {
            readings.count >= 2 ? Int(readings[readings.count - 2].glucose) : nil
        }

        private var stateColor: Color {
            guard let v = currentValue else { return TrioGlass.label(0.5) }
            return TrioGlass.Colors.state(for: Decimal(v), low: state.lowGlucose, high: state.highGlucose)
        }

        private var stateLabel: String {
            guard let v = currentValue else { return "NO DATA" }
            if Decimal(v) >= state.highGlucose { return "HIGH" }
            if Decimal(v) <= state.lowGlucose { return "LOW" }
            return "IN RANGE"
        }

        private var trendSymbol: String {
            switch readings.last?.directionEnum {
            case .doubleUp,
                 .singleUp,
                 .tripleUp: return "arrow.up"
            case .fortyFiveUp: return "arrow.up.right"
            case .flat: return "arrow.right"
            case .fortyFiveDown: return "arrow.down.right"
            case .doubleDown,
                 .singleDown,
                 .tripleDown: return "arrow.down"
            default: return "arrow.right"
            }
        }

        private var deltaText: String? {
            guard let cur = currentValue, let prev = previousValue else { return nil }
            let d = cur - prev
            return (d >= 0 ? "+\(d)" : "\(d)")
        }

        private var cob: Int { Int(state.enactedAndNonEnactedDeterminations.first?.cob ?? 0) }
        private var basal: Decimal? { state.enactedAndNonEnactedDeterminations.first?.tempBasal?.decimalValue }

        private static let num: NumberFormatter = {
            let f = NumberFormatter()
            f.numberStyle = .decimal
            f.maximumFractionDigits = 2
            return f
        }()

        private func fmt(_ d: Decimal?) -> String {
            guard let d else { return "--" }
            return Self.num.string(from: d as NSNumber) ?? "--"
        }

        // MARK: - Body

        var body: some View {
            ZStack {
                TrioGlassBackground()
                ScrollView {
                    VStack(spacing: 18) {
                        header
                        hero
                        statePillRow
                        if let progress = state.bolusProgress { bolusCard(progress) }
                        chartCard
                        GlassSectionedCard(title: "LOOP & BASAL") { loopBasalRows }
                        GlassSectionedCard(title: "POD") { podRows }
                            .contentShape(Rectangle())
                            .onTapGesture { tapPump() }
                        Color.clear.frame(height: 24)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 6)
                }
                .scrollIndicators(.hidden)
            }
            .foregroundStyle(TrioGlass.Colors.textPrimary)
        }

        // MARK: - Header

        private var header: some View {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Today").font(TrioGlass.text(13, .semibold)).foregroundStyle(TrioGlass.label(0.5))
                    Text("Glucose").font(TrioGlass.rounded(32, .heavy))
                }
                Spacer()
                Button {
                    selectedTab = 3 // Settings tab
                } label: {
                    Circle()
                        .fill(.ultraThinMaterial)
                        .overlay(Circle().strokeBorder(Color.white.opacity(0.1)))
                        .frame(width: 38, height: 38)
                        .overlay(
                            Image(systemName: "gearshape").font(.system(size: 17))
                                .foregroundStyle(TrioGlass.Colors.accent)
                        )
                }
                .buttonStyle(.plain)
            }
        }

        // MARK: - Hero (current + IOB/COB)

        private var hero: some View {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .lastTextBaseline, spacing: 8) {
                        Text(currentValue.map(String.init) ?? "--")
                            .font(TrioGlass.rounded(72, .heavy))
                            .foregroundStyle(stateColor)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("mg/dL").font(TrioGlass.text(14, .semibold)).foregroundStyle(TrioGlass.label(0.55))
                            Image(systemName: trendSymbol)
                                .font(.system(size: 16, weight: .heavy))
                                .foregroundStyle(stateColor)
                        }
                        .padding(.bottom, 10)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { tapGlucose() }
                .onLongPressGesture { longPressGlucose() }
                Spacer()
                VStack(alignment: .leading, spacing: 12) {
                    GlassStat(systemImage: "syringe", label: "IOB", value: fmt(state.currentIOB), unit: "U")
                    GlassStat(
                        systemImage: "fork.knife",
                        label: "COB",
                        value: "\(cob)",
                        unit: "g",
                        iconColor: TrioGlass.Colors.high
                    )
                }
            }
        }

        private var statePillRow: some View {
            HStack(spacing: 11) {
                GlassStatePill(text: stateLabel, color: stateColor)
                if let eventual = state.eventualBG {
                    HStack(spacing: 7) {
                        Image(systemName: "arrow.right")
                            .font(.system(size: 12, weight: .bold)).foregroundStyle(TrioGlass.label(0.4))
                        VStack(alignment: .leading, spacing: 1) {
                            Text("EVENTUAL").font(TrioGlass.text(11, .bold)).tracking(0.4).foregroundStyle(TrioGlass.label(0.45))
                            HStack(alignment: .firstTextBaseline, spacing: 2) {
                                Text("\(eventual)").font(TrioGlass.rounded(15, .heavy)).foregroundStyle(TrioGlass.label(0.82))
                                Text("mg/dL").font(TrioGlass.text(11, .semibold)).foregroundStyle(TrioGlass.label(0.45))
                            }
                        }
                    }
                }
                Spacer()
            }
        }

        // MARK: - Bolus in progress (safety: always offer Cancel)

        private func bolusCard(_ progress: Decimal) -> some View {
            let total = (state.lastPumpBolus?.bolus?.amount).map { $0 as Decimal }
            let delivered = total.map { progress * $0 }
            let frac = CGFloat(truncating: progress as NSNumber)
            return GlassCard {
                VStack(spacing: 10) {
                    HStack(spacing: 11) {
                        Image(systemName: "cross.vial.fill").font(.system(size: 18))
                            .foregroundStyle(TrioGlass.Colors.accent)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Bolusing").font(TrioGlass.rounded(15, .heavy))
                            if let total {
                                Text("\(fmt(delivered)) of \(fmt(total)) U")
                                    .font(TrioGlass.text(12.5, .semibold)).foregroundStyle(TrioGlass.label(0.55))
                            }
                        }
                        Spacer()
                        Button {
                            state.showProgressView()
                            state.cancelBolus()
                        } label: {
                            Image(systemName: "xmark.circle.fill").font(.system(size: 26))
                                .foregroundStyle(TrioGlass.Colors.urgent)
                        }
                        .buttonStyle(.plain)
                    }
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.08))
                            Capsule().fill(TrioGlass.Colors.accent)
                                .frame(width: geo.size.width * min(1, max(0, frac)))
                        }
                    }
                    .frame(height: 6)
                }
                .padding(14)
            }
        }

        // MARK: - Chart

        private var chartCard: some View {
            GlassCard(radius: TrioGlass.Metric.chartCardRadius) {
                VStack(spacing: 12) {
                    HStack {
                        Text("Last 6 Hours").font(TrioGlass.rounded(15, .heavy))
                        Spacer()
                        Text("\(fmt(state.lowGlucose))–\(fmt(state.highGlucose)) range")
                            .font(TrioGlass.text(12.5, .semibold)).foregroundStyle(TrioGlass.label(0.5))
                    }
                    glucoseChart.frame(height: 178)
                }
                .padding(14)
            }
            .contentShape(Rectangle())
            .onTapGesture { state.isLegendPresented.toggle() }
        }

        private var glucoseChart: some View {
            let lowV = Double(truncating: state.lowGlucose as NSNumber)
            let highV = Double(truncating: state.highGlucose as NSNumber)
            let pts = Array(readings.suffix(80))
            return Chart {
                RectangleMark(yStart: .value("lo", lowV), yEnd: .value("hi", highV))
                    .foregroundStyle(TrioGlass.Colors.inRange.opacity(0.10))
                RuleMark(y: .value("hi", highV))
                    .foregroundStyle(.white.opacity(0.18)).lineStyle(StrokeStyle(lineWidth: 1, dash: [1, 5]))
                RuleMark(y: .value("lo", lowV))
                    .foregroundStyle(.white.opacity(0.18)).lineStyle(StrokeStyle(lineWidth: 1, dash: [1, 5]))
                ForEach(pts, id: \.objectID) { r in
                    if let d = r.date {
                        LineMark(x: .value("t", d), y: .value("g", Double(r.glucose)), series: .value("s", "g"))
                            .interpolationMethod(.catmullRom)
                            .foregroundStyle(TrioGlass.Colors.glucoseLine)
                            .lineStyle(StrokeStyle(lineWidth: 2.6, lineCap: .round, lineJoin: .round))
                        PointMark(x: .value("t", d), y: .value("g", Double(r.glucose)))
                            .symbolSize(16)
                            .foregroundStyle(
                                TrioGlass.Colors
                                    .state(for: Decimal(Int(r.glucose)), low: state.lowGlucose, high: state.highGlucose)
                            )
                    }
                }
            }
            .chartYScale(domain: 40 ... 240)
            .chartYAxis {
                AxisMarks(position: .trailing, values: [100, 150, 200]) {
                    AxisValueLabel().font(TrioGlass.text(10, .semibold)).foregroundStyle(TrioGlass.label(0.5))
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) {
                    AxisValueLabel(format: .dateTime.hour())
                        .font(TrioGlass.text(9, .semibold)).foregroundStyle(TrioGlass.label(0.5))
                }
            }
        }

        // MARK: - Loop & Basal

        private var loopBasalRows: some View {
            VStack(spacing: 0) {
                GlassRow(icon: "arrow.triangle.2.circlepath", iconColor: TrioGlass.Colors.inRange, label: "Loop Status") {
                    HStack(spacing: 7) {
                        Circle().fill(state.closedLoop ? TrioGlass.Colors.inRange : TrioGlass.Colors.high)
                            .frame(width: 9, height: 9)
                        Text(state.closedLoop ? "Closed" : "Open")
                            .font(TrioGlass.rounded(14.5, .bold))
                            .foregroundStyle(state.closedLoop ? TrioGlass.Colors.inRange : TrioGlass.Colors.high)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { state.isLoopStatusPresented = true }
                .onLongPressGesture {
                    haptic(.medium)
                    state.runLoop()
                }
                Divider().overlay(Color.white.opacity(0.07))
                GlassRow(icon: "clock", iconColor: TrioGlass.label(0.55), label: "Last Loop") {
                    Text(lastLoopText).font(TrioGlass.rounded(14.5, .bold)).foregroundStyle(TrioGlass.label(0.85))
                }
                Divider().overlay(Color.white.opacity(0.07))
                GlassRow(icon: "drop.fill", iconColor: TrioGlass.Colors.inRange, label: "Current Basal") {
                    Text("\(fmt(basal)) U/hr").font(TrioGlass.rounded(14.5, .bold)).foregroundStyle(TrioGlass.label(0.85))
                }
            }
        }

        private var lastLoopText: String {
            let mins = max(0, Int(Date().timeIntervalSince(state.lastLoopDate) / 60))
            if state.lastLoopDate == .distantPast { return "--" }
            return mins == 0 ? "Just now" : "\(mins) min ago"
        }

        // MARK: - Pod

        private var podRows: some View {
            VStack(spacing: 11) {
                HStack {
                    HStack(spacing: 9) {
                        Image(systemName: "cylinder.fill").font(.system(size: 15)).foregroundStyle(TrioGlass.Colors.accent)
                        Text("Reservoir").font(TrioGlass.text(14.5, .medium))
                    }
                    Spacer()
                    Text(reservoirText).font(TrioGlass.rounded(15, .heavy))
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.08))
                        Capsule().fill(TrioGlass.Colors.accent).frame(width: geo.size.width * reservoirFraction)
                    }
                }
                .frame(height: 7)
                Divider().overlay(Color.white.opacity(0.07))
                HStack {
                    HStack(spacing: 9) {
                        Image(systemName: "clock").font(.system(size: 15)).foregroundStyle(TrioGlass.label(0.55))
                        Text("Pod Age").font(TrioGlass.text(14.5, .medium))
                    }
                    Spacer()
                    Text(podAgeText).font(TrioGlass.rounded(14.5, .bold)).foregroundStyle(TrioGlass.label(0.85))
                }
            }
        }

        private var reservoirText: String {
            guard let r = state.reservoir else { return "--" }
            return r >= 50 ? "50+ U" : "\(fmt(r)) U"
        }

        private var reservoirFraction: CGFloat {
            guard let r = state.reservoir else { return 0 }
            return min(1, max(0, CGFloat(truncating: r as NSNumber) / 200))
        }

        private var podAgeText: String {
            guard let start = state.pumpActivatedAtDate else { return "--" }
            let h = Int(Date().timeIntervalSince(start) / 3600)
            return "\(h / 24)d \(h % 24)h"
        }
    }

    // MARK: - Local card helpers

    /// A titled section (header + glass card) used by the dashboard groups.
    fileprivate struct GlassSectionedCard<Content: View>: View {
        let title: String
        @ViewBuilder var content: Content
        var body: some View {
            VStack(spacing: 0) {
                GlassSectionHeader(title: title)
                GlassCard { content.padding(.vertical, 4).padding(.horizontal, 16) }
            }
        }
    }

    /// One inset row: leading icon + label on the left, trailing content on the right.
    fileprivate struct GlassRow<Trailing: View>: View {
        let icon: String
        var iconColor: Color = TrioGlass.label(0.55)
        let label: String
        @ViewBuilder var trailing: Trailing
        var body: some View {
            HStack {
                HStack(spacing: 11) {
                    Image(systemName: icon).font(.system(size: 15, weight: .semibold)).foregroundStyle(iconColor)
                    Text(label).font(TrioGlass.text(14.5, .medium))
                }
                Spacer()
                trailing
            }
            .padding(.vertical, 9)
        }
    }
}
