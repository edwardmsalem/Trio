import Foundation
import Observation

/// What the glucose did after a logged meal (filled in a few hours later by the
/// outcome-learning pass).
struct MealOutcome: Codable {
    var startBG: Decimal // mg/dL at meal time
    var peakBG: Decimal // highest mg/dL within the window
    var peakMinutes: Int // minutes from meal to peak
    var endBG: Decimal // mg/dL at the end of the window
    var computedAt: Date

    var rise: Decimal { peakBG - startBG }
}

/// One meal the user actually dosed for. Drives "recents" and the
/// outcome-learning loop.
struct LoggedMeal: Codable, Identifiable {
    let id: UUID
    var date: Date
    var name: String
    var carbs: Decimal
    var fat: Decimal
    var protein: Decimal
    var source: String // "plate" | "chat" | "label" | "preset" | "manual"
    var outcome: MealOutcome?

    init(
        id: UUID = UUID(),
        date: Date = Date(),
        name: String,
        carbs: Decimal,
        fat: Decimal,
        protein: Decimal,
        source: String,
        outcome: MealOutcome? = nil
    ) {
        self.id = id
        self.date = date
        self.name = name
        self.carbs = carbs
        self.fat = fat
        self.protein = protein
        self.source = source
        self.outcome = outcome
    }
}

/// Persistent log of dosed meals. Lightweight Codable store (no Core Data
/// migration) so it is safe to add without touching the data model.
@Observable
final class MealLog {
    static let shared = MealLog()

    private(set) var meals: [LoggedMeal] = [] // newest first

    private let defaults = UserDefaults.standard
    private let storeKey = "mealLog.v1"
    private let limit = 200

    private init() {
        load()
    }

    @discardableResult
    func add(name: String, carbs: Decimal, fat: Decimal, protein: Decimal, source: String) -> LoggedMeal {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let meal = LoggedMeal(
            name: clean.isEmpty ? "Meal" : clean,
            carbs: carbs,
            fat: fat,
            protein: protein,
            source: source
        )
        meals.insert(meal, at: 0)
        if meals.count > limit { meals = Array(meals.prefix(limit)) }
        save()
        return meal
    }

    /// Most recent meals, de-duplicated by name (keeps the newest of each).
    func recents(limit: Int = 8) -> [LoggedMeal] {
        var seen = Set<String>()
        var out: [LoggedMeal] = []
        for meal in meals {
            let key = meal.name.lowercased()
            if seen.contains(key) { continue }
            seen.insert(key)
            out.append(meal)
            if out.count >= limit { break }
        }
        return out
    }

    /// Meals that still need an outcome computed and whose window has elapsed.
    func mealsNeedingOutcome(now: Date = Date(), windowHours: Double = 3) -> [LoggedMeal] {
        meals.filter { $0.outcome == nil && now.timeIntervalSince($0.date) >= windowHours * 3600 }
    }

    func setOutcome(_ outcome: MealOutcome, for id: UUID) {
        guard let idx = meals.firstIndex(where: { $0.id == id }) else { return }
        meals[idx].outcome = outcome
        save()
    }

    /// Past outcomes for meals whose name resembles the given one, for the AI to
    /// learn from ("last time you ate this you spiked to X").
    func priorOutcomes(matching name: String, limit: Int = 3) -> [LoggedMeal] {
        let needle = name.lowercased()
        guard !needle.isEmpty else { return [] }
        return meals
            .filter { $0.outcome != nil && $0.name.lowercased().contains(needle) }
            .prefix(limit)
            .map { $0 }
    }

    /// A prompt block summarising how recent meals actually landed, so the AI can
    /// calibrate its carb estimate and dosing to this user's real responses.
    func outcomesSummary(limit: Int = 6) -> String {
        let withOutcome = meals.filter { $0.outcome != nil }.prefix(limit)
        guard !withOutcome.isEmpty else { return "" }
        var lines = ["## RECENT MEAL OUTCOMES (how this user's glucose actually responded — calibrate your estimate and dosing to this)"]
        for m in withOutcome {
            guard let o = m.outcome else { continue }
            let carbs = NSDecimalNumber(decimal: m.carbs).intValue
            let peak = NSDecimalNumber(decimal: o.peakBG).intValue
            let rise = NSDecimalNumber(decimal: o.rise).intValue
            let sign = rise >= 0 ? "+" : ""
            lines.append("- \(m.name): ~\(carbs)g carbs → peaked \(peak) mg/dL (\(sign)\(rise)) at \(o.peakMinutes) min")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Persistence

    private func save() {
        if let data = try? JSONEncoder().encode(meals) {
            defaults.set(data, forKey: storeKey)
        }
    }

    private func load() {
        guard let data = defaults.data(forKey: storeKey),
              let decoded = try? JSONDecoder().decode([LoggedMeal].self, from: data)
        else { return }
        meals = decoded
    }
}
