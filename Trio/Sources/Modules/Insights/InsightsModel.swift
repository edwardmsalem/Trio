import CoreData
import Foundation
import Observation

/// One plain-English pattern surfaced on the Insights screen ("why am I high").
struct GlucosePattern: Identifiable {
    let id = UUID()
    let icon: String
    let title: String
    let detail: String
}

/// One sampled point of the loop's sensitivity ratio over time (Dynamic ISF drift).
struct ISFDriftPoint: Identifiable {
    let id = UUID()
    let date: Date
    let ratio: Double
}

/// Read-only analytics for the Insights screen. Detects recurring high-glucose
/// patterns and charts how Dynamic ISF has been drifting. All Core Data work runs
/// on a background context; results are plain value types handed back to the UI.
/// Nothing here doses or changes settings.
@Observable final class InsightsModel {
    var highPatterns: [GlucosePattern] = []
    var isfDriftPoints: [ISFDriftPoint] = []
    var isLoading = false
    var hasLoaded = false

    let units: GlucoseUnits
    private let highThreshold: Int
    private let lowThreshold: Int

    init(units: GlucoseUnits = .mgdL, highThreshold: Int = 180, lowThreshold: Int = 70) {
        self.units = units
        self.highThreshold = highThreshold
        self.lowThreshold = lowThreshold
    }

    private struct AnalysisResult {
        let patterns: [GlucosePattern]
        let drift: [ISFDriftPoint]
    }

    @MainActor func load(days: Int = 14) async {
        guard !isLoading else { return }
        isLoading = true
        let result = await analyze(days: days)
        highPatterns = result.patterns
        isfDriftPoints = result.drift
        isLoading = false
        hasLoaded = true
    }

    private func analyze(days: Int) async -> AnalysisResult {
        let high = highThreshold
        let units = units
        return await withCheckedContinuation { (continuation: CheckedContinuation<AnalysisResult, Never>) in
            let context = CoreDataStack.shared.newTaskContext()
            context.perform {
                let start = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
                let calendar = Calendar.current

                // Format an mg/dL delta in the user's units.
                func fmt(_ mgdl: Double) -> String {
                    if units == .mmolL {
                        return Decimal(mgdl).asMmolL.description + " mmol/L"
                    }
                    return "\(Int(mgdl.rounded())) mg/dL"
                }

                // MARK: Glucose patterns (B2)

                var patterns: [GlucosePattern] = []
                let glucoseRequest: NSFetchRequest<GlucoseStored> = GlucoseStored.fetchRequest()
                glucoseRequest.predicate = NSPredicate(format: "date >= %@", start as NSDate)
                glucoseRequest.sortDescriptors = [NSSortDescriptor(key: "date", ascending: true)]
                let readings = (try? context.fetch(glucoseRequest)) ?? []

                if readings.count >= 200 { // need a couple of days of CGM data
                    var sum = [Int](repeating: 0, count: 24)
                    var count = [Int](repeating: 0, count: 24)
                    var highCount = [Int](repeating: 0, count: 24)
                    for reading in readings {
                        guard let date = reading.date else { continue }
                        let hour = calendar.component(.hour, from: date)
                        let value = Int(reading.glucose)
                        sum[hour] += value
                        count[hour] += 1
                        if value > high { highCount[hour] += 1 }
                    }

                    func avg(_ hours: [Int]) -> Double {
                        let c = hours.reduce(0) { $0 + count[$1] }
                        let s = hours.reduce(0) { $0 + sum[$1] }
                        return c > 0 ? Double(s) / Double(c) : 0
                    }
                    func highPct(_ hours: [Int]) -> Double {
                        let c = hours.reduce(0) { $0 + count[$1] }
                        let hi = hours.reduce(0) { $0 + highCount[$1] }
                        return c > 0 ? Double(hi) / Double(c) * 100 : 0
                    }

                    // Dawn phenomenon: early-morning climb vs. overnight baseline.
                    let overnight = avg([0, 1, 2, 3])
                    let dawn = avg([5, 6, 7, 8])
                    if overnight > 0, dawn - overnight >= 25 {
                        patterns.append(GlucosePattern(
                            icon: "sunrise.fill",
                            title: "Dawn phenomenon",
                            detail: "Your glucose tends to climb in the early morning — about \(fmt(dawn - overnight)) higher around 5–8 AM than overnight. This is common and may call for more basal in the pre-dawn hours."
                        ))
                    }

                    // Evening highs after dinner.
                    let dinnerPct = highPct([19, 20, 21, 22])
                    if dinnerPct >= 40 {
                        patterns.append(GlucosePattern(
                            icon: "moon.stars.fill",
                            title: "Evening highs",
                            detail: "You're above \(high > 0 ? fmt(Double(high)) : "target") about \(Int(dinnerPct))% of the time between 7 and 11 PM. Dinner carbs or timing may be worth a look."
                        ))
                    }

                    // Worst 3-hour window overall, if not already explained above.
                    var worstStart = -1
                    var worstPct = 0.0
                    for h in 0 ..< 24 {
                        let window = [h % 24, (h + 1) % 24, (h + 2) % 24]
                        let pct = highPct(window)
                        if pct > worstPct { worstPct = pct
                            worstStart = h }
                    }
                    let alreadyCovered = (worstStart >= 5 && worstStart <= 8) || (worstStart >= 18 && worstStart <= 22)
                    if worstStart >= 0, worstPct >= 50, !alreadyCovered {
                        let endHour = (worstStart + 3) % 24
                        patterns.append(GlucosePattern(
                            icon: "clock.badge.exclamationmark.fill",
                            title: "Recurring highs",
                            detail: "Your most frequent highs cluster around \(worstStart):00–\(endHour):00 — above target about \(Int(worstPct))% of the time in that window."
                        ))
                    }
                }

                // MARK: ISF drift (D1)

                let determinationRequest: NSFetchRequest<OrefDetermination> = OrefDetermination.fetchRequest()
                determinationRequest.predicate = NSPredicate(
                    format: "deliverAt >= %@ AND sensitivityRatio > 0",
                    start as NSDate
                )
                determinationRequest.sortDescriptors = [NSSortDescriptor(key: "deliverAt", ascending: true)]
                let determinations = (try? context.fetch(determinationRequest)) ?? []
                let allDrift: [ISFDriftPoint] = determinations.compactMap { det in
                    guard let date = det.deliverAt, let ratio = det.sensitivityRatio?.doubleValue, ratio > 0 else { return nil }
                    return ISFDriftPoint(date: date, ratio: ratio)
                }
                // Downsample so the chart stays light (~300 points max).
                let step = max(1, allDrift.count / 300)
                let drift = step == 1 ? allDrift : allDrift.enumerated().compactMap { $0.offset % step == 0 ? $0.element : nil }

                continuation.resume(returning: AnalysisResult(patterns: patterns, drift: drift))
            }
        }
    }
}
