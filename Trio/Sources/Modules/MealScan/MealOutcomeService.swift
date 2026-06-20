import CoreData
import Foundation

/// Closes the outcome-learning loop: for each logged meal whose 3-hour window has
/// passed, reads Trio's glucose history and records how the meal landed (start,
/// peak, time-to-peak, end). Read-only against the glucose store.
enum MealOutcomeService {
    /// Compute outcomes for any meals that are due. Call on the bolus screen
    /// appearing; cheap and idempotent (skips meals already scored).
    static func backfill(windowHours: Double = 3) {
        let log = MealLog.shared
        let pending = log.mealsNeedingOutcome(windowHours: windowHours)
        guard !pending.isEmpty else { return }

        let context = CoreDataStack.shared.persistentContainer.viewContext
        context.perform {
            for meal in pending {
                let start = meal.date
                let end = start.addingTimeInterval(windowHours * 3600)

                let request: NSFetchRequest<GlucoseStored> = GlucoseStored.fetchRequest()
                request.predicate = NSPredicate(
                    format: "date >= %@ AND date <= %@",
                    start as NSDate,
                    end as NSDate
                )
                request.sortDescriptors = [NSSortDescriptor(key: "date", ascending: true)]

                guard let readings = try? context.fetch(request) else { continue }
                let points: [(date: Date, value: Int16)] = readings.compactMap { r in
                    guard let d = r.date else { return nil }
                    return (d, r.glucose)
                }
                guard let first = points.first, let last = points.last, points.count >= 2 else { continue }

                var peak = first
                for p in points where p.value > peak.value { peak = p }

                // v2: the sampled post-meal curve. CGM readings are already ~5 min
                // apart, so we keep them as-is, anchored as minutes-from-meal.
                let curve: [CurvePoint] = points.map { p in
                    CurvePoint(
                        minutesFromStart: max(0, Int(p.date.timeIntervalSince(start) / 60)),
                        glucose: Int(p.value)
                    )
                }

                // v2: total bolus insulin delivered during the meal's window.
                let bolusRequest: NSFetchRequest<BolusStored> = BolusStored.fetchRequest()
                bolusRequest.predicate = NSPredicate(
                    format: "pumpEvent.timestamp >= %@ AND pumpEvent.timestamp <= %@",
                    start as NSDate,
                    end as NSDate
                )
                let insulinDelivered: Decimal? = (try? context.fetch(bolusRequest)).map { boluses in
                    boluses.reduce(Decimal(0)) { $0 + (($1.amount?.decimalValue) ?? 0) }
                }

                // v2: loop context at meal time — carbs-on-board plus the ISF and
                // carb ratio in effect, from the most recent determination at or
                // before the meal. These let us back-calculate the implied carbs.
                let determinationRequest: NSFetchRequest<OrefDetermination> = OrefDetermination.fetchRequest()
                determinationRequest.predicate = NSPredicate(format: "deliverAt <= %@", start as NSDate)
                determinationRequest.sortDescriptors = [NSSortDescriptor(key: "deliverAt", ascending: false)]
                determinationRequest.fetchLimit = 1
                let determination = (try? context.fetch(determinationRequest))?.first
                let cobAtStart: Int? = determination.map { Int($0.cob) }
                let isfAtStart: Decimal? = determination?.insulinSensitivity?.decimalValue
                let carbRatioAtStart: Decimal? = determination?.carbRatio?.decimalValue

                let outcome = MealOutcome(
                    startBG: Decimal(first.value),
                    peakBG: Decimal(peak.value),
                    peakMinutes: max(0, Int(peak.date.timeIntervalSince(start) / 60)),
                    endBG: Decimal(last.value),
                    computedAt: Date(),
                    curve: curve,
                    insulinDelivered: insulinDelivered,
                    cobAtStart: cobAtStart,
                    isfAtStart: isfAtStart,
                    carbRatioAtStart: carbRatioAtStart
                )

                DispatchQueue.main.async {
                    log.setOutcome(outcome, for: meal.id)
                }
            }
        }
    }
}
