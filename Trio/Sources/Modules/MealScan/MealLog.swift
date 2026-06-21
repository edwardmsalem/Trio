import Foundation
import Observation

/// One sampled glucose point on a meal's post-meal curve. Minutes are measured
/// from the meal time so a chart can re-anchor the curve against
/// `LoggedMeal.date` without storing absolute timestamps per point.
struct CurvePoint: Codable {
    var minutesFromStart: Int
    var glucose: Int // mg/dL
}

/// What the glucose did after a logged meal (filled in a few hours later by the
/// outcome-learning pass).
struct MealOutcome: Codable {
    var startBG: Decimal // mg/dL at meal time
    var peakBG: Decimal // highest mg/dL within the window
    var peakMinutes: Int // minutes from meal to peak
    var endBG: Decimal // mg/dL at the end of the window
    var computedAt: Date

    // v2 fields — all optional so older `mealLog.v1` entries (which lack them)
    // decode unchanged. Synthesized Codable uses decodeIfPresent for optionals.
    var curve: [CurvePoint]? = nil // sampled BG across the post-meal window
    var insulinDelivered: Decimal? = nil // total bolus units delivered in the window
    var cobAtStart: Int? = nil // carbs-on-board (g) at meal time, from the loop
    var isfAtStart: Decimal? = nil // insulin sensitivity (mg/dL per U) in effect at meal time
    var carbRatioAtStart: Decimal? = nil // carb ratio (g per U) in effect at meal time

    var rise: Decimal { peakBG - startBG }

    /// Rough back-calculation of how many carbs the glucose response actually
    /// looked like, from the net rise and the insulin delivered, using the ISF
    /// and carb ratio that were in effect. 1 g raises BG by ISF/CR; 1 U lowers it
    /// by ISF, so impliedCarbs = rise*CR/ISF + insulin*CR. Returns nil when the
    /// inputs needed are missing or implausible. Advisory only — never dosing.
    var impliedCarbs: Decimal? {
        guard let isf = isfAtStart, isf > 0,
              let cr = carbRatioAtStart, cr > 0
        else { return nil }
        let insulin = insulinDelivered ?? 0
        let implied = (rise * cr / isf) + (insulin * cr)
        return implied > 0 ? implied : nil
    }
}

/// Advisory shown when a fresh scan resembles past meals: what they actually did
/// to glucose, and (when derivable) how many carbs the response looked like.
/// Purely informational — the user accepts or ignores it.
struct MealAdjustmentAdvisory {
    let matchCount: Int
    let avgPeak: Int // mg/dL
    let avgRise: Int // mg/dL
    let avgPeakMinutes: Int
    let loggedCarbs: Int // average carbs logged across the matches
    let impliedCarbs: Int? // back-calculated from the glucose response, if available
    let suggestion: String // plain-English line for the UI
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
@Observable final class MealLog {
    static let shared = MealLog()

    private(set) var meals: [LoggedMeal] = [] // newest first

    private let defaults = UserDefaults.standard
    private let storeKey = "mealLog.v1"
    private let limit = 200

    private init() {
        load()
    }

    @discardableResult func add(name: String, carbs: Decimal, fat: Decimal, protein: Decimal, source: String) -> LoggedMeal {
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

    /// Lowercase, strip punctuation, collapse whitespace — so "Kibbeh Dinner!"
    /// and "kibbeh  dinner" dedupe together.
    static func normalizedName(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(.whitespaces)
        let cleaned = name.lowercased().unicodeScalars.filter { allowed.contains($0) }
        return String(String.UnicodeScalarView(cleaned))
            .split(separator: " ")
            .joined(separator: " ")
    }

    /// Most recent meals, fuzzy-deduplicated by name (keeps the newest of each).
    /// Two names are duplicates when their normalized forms match or one
    /// contains the other ("kibbeh dinner" vs "kibbeh dinner with challah").
    func recents(limit: Int = 8) -> [LoggedMeal] {
        var seenKeys: [String] = []
        var out: [LoggedMeal] = []
        for meal in meals {
            let key = Self.normalizedName(meal.name)
            guard !key.isEmpty else { continue }
            if seenKeys.contains(where: { $0 == key || $0.contains(key) || key.contains($0) }) { continue }
            seenKeys.append(key)
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

    /// Advisory comparing a fresh estimate against how the same meal actually
    /// landed before. Surfaced to the user; never mutates the carb field or doses.
    func adjustmentAdvisory(forName name: String, currentCarbs: Decimal) -> MealAdjustmentAdvisory? {
        let key = Self.normalizedName(name)
        guard !key.isEmpty else { return nil }

        let matches = meals.filter { meal in
            guard meal.outcome != nil else { return false }
            let mealKey = Self.normalizedName(meal.name)
            guard !mealKey.isEmpty else { return false }
            return mealKey == key || mealKey.contains(key) || key.contains(mealKey)
        }
        .prefix(5)
        .map { $0 }

        guard !matches.isEmpty else { return nil }

        func avgInt(_ values: [Decimal]) -> Int {
            guard !values.isEmpty else { return 0 }
            let sum = values.reduce(Decimal(0), +)
            return NSDecimalNumber(decimal: sum / Decimal(values.count)).intValue
        }

        let outcomes = matches.compactMap(\.outcome)
        let avgPeak = avgInt(outcomes.map(\.peakBG))
        let avgRise = avgInt(outcomes.map(\.rise))
        let avgPeakMinutes = avgInt(outcomes.map { Decimal($0.peakMinutes) })
        let avgLoggedCarbs = avgInt(matches.map(\.carbs))

        let impliedValues = outcomes.compactMap(\.impliedCarbs)
        let avgImplied: Int? = impliedValues.isEmpty ? nil : avgInt(impliedValues)

        let current = NSDecimalNumber(decimal: currentCarbs).intValue
        let empirical =
            "Last \(matches.count == 1 ? "time" : "\(matches.count) times") you logged this (~\(avgLoggedCarbs)g) it peaked \(avgPeak) (+\(avgRise)) around \(avgPeakMinutes) min."

        var suggestion = empirical
        if let implied = avgImplied, current > 0 {
            let diff = implied - current
            // Only nudge when the gap is both proportionally and absolutely real.
            if implied > current, Double(implied) > Double(current) * 1.15, diff >= 8 {
                suggestion = empirical + " The response looked more like ~\(implied)g — consider estimating a little higher."
            } else if implied < current, Double(implied) < Double(current) * 0.85, -diff >= 8 {
                suggestion = empirical + " The response looked more like ~\(implied)g — you may be over-estimating."
            }
        }

        return MealAdjustmentAdvisory(
            matchCount: matches.count,
            avgPeak: avgPeak,
            avgRise: avgRise,
            avgPeakMinutes: avgPeakMinutes,
            loggedCarbs: avgLoggedCarbs,
            impliedCarbs: avgImplied,
            suggestion: suggestion
        )
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
        var lines =
            ["## RECENT MEAL OUTCOMES (how this user's glucose actually responded — calibrate your estimate and dosing to this)"]
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
