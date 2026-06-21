import Charts
import SwiftUI

/// Advisory analytics screen: recurring high-glucose patterns and Dynamic ISF
/// drift. Read-only — it explains trends, it never changes settings or doses.
struct InsightsView: View {
    @State private var model: InsightsModel

    @Environment(\.dismiss) private var dismiss

    init(units: GlucoseUnits = .mgdL, highThreshold: Int = 180, lowThreshold: Int = 70) {
        _model = State(initialValue: InsightsModel(units: units, highThreshold: highThreshold, lowThreshold: lowThreshold))
    }

    var body: some View {
        NavigationStack {
            List {
                patternsSection
                isfDriftSection
            }
            .navigationTitle("Insights")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .overlay {
                if model.isLoading {
                    ProgressView()
                }
            }
            .task {
                if !model.hasLoaded { await model.load() }
            }
        }
    }

    // MARK: - Patterns (B2)

    @ViewBuilder private var patternsSection: some View {
        Section {
            if model.hasLoaded, model.highPatterns.isEmpty {
                Text("No clear recurring patterns over the last 2 weeks. Keep logging and check back.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.highPatterns) { pattern in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: pattern.icon)
                            .font(.title3)
                            .foregroundStyle(.orange)
                            .frame(width: 26)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(pattern.title)
                                .font(.subheadline)
                                .fontWeight(.semibold)
                            Text(pattern.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        } header: {
            Text("Why am I high")
        } footer: {
            Text("Patterns are observations from your last 2 weeks, not medical advice. Discuss changes with your care team.")
        }
    }

    // MARK: - ISF drift (D1)

    @ViewBuilder private var isfDriftSection: some View {
        Section {
            if model.isfDriftPoints.isEmpty {
                if model.hasLoaded {
                    Text("Not enough loop data yet to chart sensitivity.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else {
                Chart {
                    ForEach(model.isfDriftPoints) { point in
                        LineMark(
                            x: .value("Date", point.date),
                            y: .value("Sensitivity", point.ratio)
                        )
                        .foregroundStyle(Color.insulin)
                        .interpolationMethod(.catmullRom)
                    }
                    RuleMark(y: .value("Baseline", 1.0))
                        .lineStyle(.init(lineWidth: 0.5, dash: [4, 4]))
                        .foregroundStyle(.secondary)
                }
                .chartYAxisLabel("Sensitivity ratio")
                .frame(height: 200)
                .padding(.vertical, 4)
            }
        } header: {
            Text("Dynamic ISF drift")
        } footer: {
            Text("Above 1.0 means the loop is dosing more aggressively than your baseline ISF; below 1.0, more conservatively.")
        }
    }
}
