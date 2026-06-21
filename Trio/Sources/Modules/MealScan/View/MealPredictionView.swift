import Charts
import SwiftUI

extension MealScan {
    /// Pre-meal projection: draws Trio's own predicted glucose curves for the
    /// scanned carbs so the user can see the likely peak and landing before they
    /// eat. Carbs-only (no manual bolus) — it is a read-only projection and never
    /// doses. Mirrors the Treatments forecast chart's line styling.
    struct MealPredictionView: View {
        let determination: Determination?
        let units: GlucoseUnits
        let carbs: Decimal

        @Environment(\.dismiss) private var dismiss

        // Standard time-in-range bounds (matches the Stat module's 70/180).
        private let lowBound = 70
        private let highBound = 180
        private let horizonPoints = 36 // 36 * 5 min = 3 h

        var body: some View {
            NavigationStack {
                Group {
                    if let predictions = determination?.predictions, hasData(predictions) {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 20) {
                                summaryRow(predictions)
                                chart(predictions)
                                disclaimer
                            }
                            .padding()
                        }
                    } else {
                        ContentUnavailableView(
                            "No projection available",
                            systemImage: "chart.xyaxis.line",
                            description: Text(
                                "Trio needs recent glucose and loop data to project a meal. Try again in a few minutes."
                            )
                        )
                    }
                }
                .navigationTitle("Projected Impact")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
            }
        }

        // MARK: - Summary

        private func summaryRow(_ predictions: Predictions) -> some View {
            HStack(spacing: 12) {
                metric(
                    title: "Carbs",
                    value: "\(NSDecimalNumber(decimal: carbs).intValue) g",
                    color: .orange
                )
                metric(
                    title: "Projected peak",
                    value: peakValue(predictions).map { "\($0.formatted(withUnits: units))" } ?? "--",
                    color: .red
                )
                metric(
                    title: "Lands near",
                    value: determination?.eventualBG.map { $0.formatted(withUnits: units) } ?? "--",
                    color: .blue
                )
            }
        }

        private func metric(title: String, value: String, color: Color) -> some View {
            VStack(spacing: 4) {
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.headline)
                    .foregroundStyle(color)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
        }

        // MARK: - Chart

        private func chart(_ predictions: Predictions) -> some View {
            let series: [(String, [Int])] = [
                ("iob", Array((predictions.iob ?? []).prefix(horizonPoints))),
                ("zt", Array((predictions.zt ?? []).prefix(horizonPoints))),
                ("cob", Array((predictions.cob ?? []).prefix(horizonPoints))),
                ("uam", Array((predictions.uam ?? []).prefix(horizonPoints)))
            ]

            return Chart {
                ForEach(series, id: \.0) { name, values in
                    ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                        LineMark(
                            x: .value("Minutes", index * 5),
                            y: .value("Glucose", chartY(value)),
                            series: .value("Type", name)
                        )
                        .foregroundStyle(by: .value("Prediction Type", name))
                    }
                }

                RuleMark(y: .value("High", chartY(highBound)))
                    .lineStyle(.init(lineWidth: 0.5, dash: [3, 3]))
                    .foregroundStyle(.orange.opacity(0.5))
                RuleMark(y: .value("Low", chartY(lowBound)))
                    .lineStyle(.init(lineWidth: 0.5, dash: [3, 3]))
                    .foregroundStyle(.red.opacity(0.5))
            }
            .chartForegroundStyleScale([
                "iob": Color.insulin,
                "uam": Color.uam,
                "zt": Color.zt,
                "cob": Color.orange
            ])
            .chartXAxisLabel("Minutes from now")
            .chartXScale(domain: 0 ... (horizonPoints * 5))
            .frame(height: 260)
            .chartLegend(position: .bottom)
        }

        private var disclaimer: some View {
            Text(
                "Projection assumes you log these carbs and let Trio respond automatically — no manual bolus. A bolus you give will lower the peak. This never doses on its own."
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
        }

        // MARK: - Helpers

        private func hasData(_ predictions: Predictions) -> Bool {
            [predictions.iob, predictions.zt, predictions.cob, predictions.uam]
                .compactMap { $0 }
                .contains { !$0.isEmpty }
        }

        private func chartY(_ mgdl: Int) -> Decimal {
            Decimal(mgdl).asUnit(units)
        }

        /// Highest projected value across all curves (the peak to warn about).
        private func peakValue(_ predictions: Predictions) -> Int? {
            [predictions.iob, predictions.zt, predictions.cob, predictions.uam]
                .compactMap { $0 }
                .flatMap { $0.prefix(horizonPoints) }
                .max()
        }
    }
}
