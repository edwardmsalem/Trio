import Charts
import SwiftUI

extension MealScan {
    /// Browsable history of logged meals with each meal's own post-meal glucose
    /// curve (captured by `MealOutcomeService`). Data-only — no photos are stored
    /// or shown. Read-only; nothing here doses.
    struct MealHistoryView: View {
        var units: GlucoseUnits = .mgdL

        @Environment(\.dismiss) private var dismiss

        private var meals: [LoggedMeal] { MealLog.shared.meals }

        var body: some View {
            NavigationStack {
                Group {
                    if meals.isEmpty {
                        ContentUnavailableView(
                            "No meals yet",
                            systemImage: "fork.knife",
                            description: Text("Meals you log with carbs will appear here, with the glucose curve that followed.")
                        )
                    } else {
                        List {
                            ForEach(meals) { meal in
                                if meal.outcome?.curve?.isEmpty == false {
                                    NavigationLink {
                                        MealDetailView(meal: meal, units: units)
                                    } label: {
                                        MealRow(meal: meal)
                                    }
                                } else {
                                    MealRow(meal: meal)
                                }
                            }
                        }
                    }
                }
                .navigationTitle("Meal History")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
            }
        }
    }

    // MARK: - Row

    private struct MealRow: View {
        let meal: LoggedMeal

        var body: some View {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(meal.name)
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Spacer()
                    Text(meal.date.formatted(.dateTime.month().day().hour().minute()))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 10) {
                    Text("C \(NSDecimalNumber(decimal: meal.carbs).intValue)g").foregroundStyle(.blue)
                    Text("F \(NSDecimalNumber(decimal: meal.fat).intValue)g").foregroundStyle(.orange)
                    Text("P \(NSDecimalNumber(decimal: meal.protein).intValue)g").foregroundStyle(.red)

                    if let outcome = meal.outcome {
                        Spacer()
                        let rise = NSDecimalNumber(decimal: outcome.rise).intValue
                        Label(
                            "\(NSDecimalNumber(decimal: outcome.peakBG).intValue) (\(rise >= 0 ? "+" : "")\(rise))",
                            systemImage: "arrow.up.right"
                        )
                        .foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
            }
            .padding(.vertical, 2)
        }
    }

    // MARK: - Detail

    private struct MealDetailView: View {
        let meal: LoggedMeal
        let units: GlucoseUnits

        private let lowBound = 70
        private let highBound = 180

        var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    if let curve = meal.outcome?.curve, !curve.isEmpty {
                        curveChart(curve)
                    }
                    contextRows
                }
                .padding()
            }
            .navigationTitle(meal.name)
            .navigationBarTitleDisplayMode(.inline)
        }

        private var header: some View {
            HStack(spacing: 12) {
                metric("Carbs", "\(NSDecimalNumber(decimal: meal.carbs).intValue) g", .orange)
                if let o = meal.outcome {
                    metric("Peak", "\(NSDecimalNumber(decimal: o.peakBG).intValue)".glucoseDisplay(units), .red)
                    metric("Time to peak", "\(o.peakMinutes) min", .blue)
                }
            }
        }

        private func metric(_ title: String, _ value: String, _ color: Color) -> some View {
            VStack(spacing: 4) {
                Text(title).font(.caption2).foregroundStyle(.secondary)
                Text(value).font(.headline).foregroundStyle(color)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
        }

        private func curveChart(_ curve: [CurvePoint]) -> some View {
            Chart {
                ForEach(Array(curve.enumerated()), id: \.offset) { _, point in
                    LineMark(
                        x: .value("Minutes", point.minutesFromStart),
                        y: .value("Glucose", chartY(point.glucose))
                    )
                    .foregroundStyle(Color.green)
                    .interpolationMethod(.catmullRom)
                }

                // Carbs logged at meal time.
                PointMark(x: .value("Minutes", 0), y: .value("Glucose", chartY(curve.first?.glucose ?? lowBound)))
                    .symbol {
                        Image(systemName: "fork.knife").font(.caption2).foregroundStyle(.orange)
                    }

                RuleMark(y: .value("High", chartY(highBound)))
                    .lineStyle(.init(lineWidth: 0.5, dash: [3, 3]))
                    .foregroundStyle(.orange.opacity(0.5))
                RuleMark(y: .value("Low", chartY(lowBound)))
                    .lineStyle(.init(lineWidth: 0.5, dash: [3, 3]))
                    .foregroundStyle(.red.opacity(0.5))
            }
            .chartXAxisLabel("Minutes after meal")
            .frame(height: 240)
        }

        @ViewBuilder private var contextRows: some View {
            if let o = meal.outcome {
                VStack(alignment: .leading, spacing: 8) {
                    if let insulin = o.insulinDelivered {
                        contextRow(
                            "Insulin delivered",
                            "\(NSDecimalNumber(decimal: insulin).doubleValue.formatted(.number.precision(.fractionLength(0 ... 2)))) U"
                        )
                    }
                    if let cob = o.cobAtStart {
                        contextRow("Carbs on board at start", "\(cob) g")
                    }
                    if let implied = o.impliedCarbs {
                        contextRow(
                            "Response looked like",
                            "~\(NSDecimalNumber(decimal: implied).intValue) g carbs"
                        )
                    }
                }
                .font(.caption)
            }
        }

        private func contextRow(_ label: String, _ value: String) -> some View {
            HStack {
                Text(label).foregroundStyle(.secondary)
                Spacer()
                Text(value).foregroundStyle(.primary)
            }
        }

        private func chartY(_ mgdl: Int) -> Decimal {
            Decimal(mgdl).asUnit(units)
        }
    }
}

private extension String {
    /// Appends the unit label, converting the numeric mg/dL string when needed.
    func glucoseDisplay(_ units: GlucoseUnits) -> String {
        guard let mgdl = Int(self) else { return self }
        return mgdl.formatted(withUnits: units)
    }
}
