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

    /// Live physiology snapshot for the AI Meal Advisor when it's opened outside
    /// the bolus screen (e.g. from the Home Screen widget), so its advice still
    /// uses real numbers instead of running blind. Reads the most recent
    /// determination (ISF, carb ratio, target, IOB, COB) and the latest glucose
    /// readings (current BG + recent delta). Returns nil if there's no data yet,
    /// in which case the advisor simply runs without live context.
    static func liveMealContext() -> MealContext? {
        let context = CoreDataStack.shared.persistentContainer.viewContext
        var result: MealContext?
        context.performAndWait {
            // Latest few readings (~15 min) for current BG and a recent delta.
            let glucoseRequest: NSFetchRequest<GlucoseStored> = GlucoseStored.fetchRequest()
            glucoseRequest.sortDescriptors = [NSSortDescriptor(key: "date", ascending: false)]
            glucoseRequest.fetchLimit = 4
            let readings = (try? context.fetch(glucoseRequest)) ?? []
            guard let latest = readings.first else { return }
            let currentBG = Decimal(latest.glucose)
            let deltaBG: Decimal = readings.count >= 2
                ? Decimal(latest.glucose) - Decimal(readings[readings.count - 1].glucose)
                : 0

            // Most recent determination for the loop's live ISF / CR / target / IOB / COB.
            let determinationRequest: NSFetchRequest<OrefDetermination> = OrefDetermination.fetchRequest()
            determinationRequest.sortDescriptors = [NSSortDescriptor(key: "deliverAt", ascending: false)]
            determinationRequest.fetchLimit = 1
            let determination = (try? context.fetch(determinationRequest))?.first

            result = MealContext(
                glucose: currentBG,
                deltaBG: deltaBG,
                iob: determination?.iob?.decimalValue ?? 0,
                cob: determination?.cob ?? 0,
                isf: determination?.insulinSensitivity?.decimalValue ?? 0,
                carbRatio: determination?.carbRatio?.decimalValue ?? 0,
                target: determination?.currentTarget?.decimalValue ?? 0
            )
        }
        return result
    }
}
