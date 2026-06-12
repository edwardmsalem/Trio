import Foundation

// MARK: - Meal Scan Phase

enum MealScanPhase {
    case camera
    case analyzing
    case chat
    case confirming
}

// MARK: - Detected Food

struct DetectedFood: Identifiable {
    let id: UUID
    let foodId: Int?
    var name: String
    var foodType: String // "Generic" or "Brand"
    var nameSingular: String
    var namePlural: String
    var servingDescription: String
    var portionGrams: Double
    var perUnitGrams: Double
    var carbs: Decimal
    var fat: Decimal
    var protein: Decimal
    var calories: Decimal
    var sugar: Decimal
    var fiber: Decimal
    var alternativeServings: [ServingOption]
    var isRemoved: Bool
    var isUserAdjusted: Bool

    init(
        foodId: Int? = nil,
        name: String,
        foodType: String = "Generic",
        nameSingular: String = "",
        namePlural: String = "",
        servingDescription: String = "",
        portionGrams: Double = 0,
        perUnitGrams: Double = 0,
        carbs: Decimal,
        fat: Decimal,
        protein: Decimal,
        calories: Decimal,
        sugar: Decimal = 0,
        fiber: Decimal = 0,
        alternativeServings: [ServingOption] = []
    ) {
        self.id = UUID()
        self.foodId = foodId
        self.name = name
        self.foodType = foodType
        self.nameSingular = nameSingular
        self.namePlural = namePlural
        self.servingDescription = servingDescription
        self.portionGrams = portionGrams
        self.perUnitGrams = perUnitGrams
        self.carbs = carbs
        self.fat = fat
        self.protein = protein
        self.calories = calories
        self.sugar = sugar
        self.fiber = fiber
        self.alternativeServings = alternativeServings
        self.isRemoved = false
        self.isUserAdjusted = false
    }
}

// MARK: - Serving Option

struct ServingOption: Identifiable {
    let id: String // serving_id from FatSecret
    let description: String
    let metricAmount: Double
    let metricUnit: String
    let numberOfUnits: String
    let isDefault: Bool
    let carbs: Decimal
    let fat: Decimal
    let protein: Decimal
    let calories: Decimal
    let sugar: Decimal
}

// MARK: - Super Bolus Recommendation

enum SuperBolusRecommendation: String, Codable {
    case yes
    case consider
    case no
}

// MARK: - Meal Speed

enum MealSpeed: String, Codable {
    case fast
    case medium
    case slow
    case mixed
}

// MARK: - Confidence Level

enum ConfidenceLevel: String, Codable {
    case high
    case medium
    case low
}

// MARK: - Meal Context (live physiology snapshot for the AI)

/// A snapshot of the user's current state, captured when the meal advisor opens,
/// so the AI can give dosing-aware advice instead of generic estimates.
/// All glucose-derived values are mg/dL (Trio's internal canonical unit).
struct MealContext {
    var glucose: Decimal // mg/dL
    var deltaBG: Decimal // mg/dL change over ~20 min
    var iob: Decimal // units of insulin on board
    var cob: Int16 // grams of carbs on board
    var isf: Decimal // mg/dL drop per unit
    var carbRatio: Decimal // grams covered per unit
    var target: Decimal // mg/dL

    private var trendPhrase: String {
        switch deltaBG {
        case let d where d >= 15: return "rising fast"
        case let d where d >= 5: return "rising"
        case let d where d <= -15: return "falling fast"
        case let d where d <= -5: return "falling"
        default: return "steady"
        }
    }

    private static func num(_ d: Decimal) -> String {
        NSDecimalNumber(decimal: d).doubleValue.formatted(.number.precision(.fractionLength(0 ... 1)))
    }

    /// BG-tier multiplier applied to ISF (ported from Eddie's OmniBot advisor).
    var isfTierMultiplier: Decimal {
        switch glucose {
        case ..<70: return Decimal(string: "1.2")!
        case ..<140: return 1
        case ..<200: return Decimal(string: "0.9")!
        case ..<250: return Decimal(string: "0.8")!
        default: return Decimal(string: "0.7")!
        }
    }

    /// Same advisory-dose formula the AI is instructed to use:
    /// meal (net carbs / CR) + correction ((BG - target) / tiered ISF) - IOB.
    /// Used to sanity-check the AI's arithmetic, never to dose.
    func advisoryDose(netCarbs: Decimal) -> Decimal? {
        guard glucose > 0, carbRatio > 0, isf > 0 else { return nil }
        let meal = netCarbs / carbRatio
        let tieredISF = isf * isfTierMultiplier
        let correction = tieredISF > 0 ? (glucose - target) / tieredISF : 0
        return meal + correction - iob
    }

    /// A compact block prepended to the AI's first message. Empty if no live data.
    var promptBlock: String {
        guard glucose > 0 else { return "" }
        var lines = ["## CURRENT STATE (live from the pump, factor this into your dosing guidance)"]
        let sign = deltaBG >= 0 ? "+" : ""
        lines.append("- Glucose: \(Self.num(glucose)) mg/dL, \(trendPhrase) (\(sign)\(Self.num(deltaBG)) mg/dL over ~20 min)")
        lines.append("- Insulin on board (IOB): \(Self.num(iob)) U")
        lines.append("- Carbs on board (COB): \(cob) g")
        if isf > 0 { lines.append("- Insulin sensitivity (ISF): 1 U drops ~\(Self.num(isf)) mg/dL") }
        if carbRatio > 0 { lines.append("- Carb ratio (CR): 1 U covers ~\(Self.num(carbRatio)) g carbs") }
        if target > 0 { lines.append("- Target glucose: \(Self.num(target)) mg/dL") }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Nutrition Totals

struct NutritionTotals: Codable {
    var carbs: Decimal
    var fat: Decimal
    var protein: Decimal
    var calories: Decimal
    var sugar: Decimal
    var fiber: Decimal
    var netCarbs: Decimal
    var fpu: Decimal
    var fpuAbsorptionHours: Decimal
    var speed: MealSpeed
    var confidence: ConfidenceLevel
    var superBolusRecommendation: SuperBolusRecommendation
    var superBolusReason: String
    /// Short dish name from the AI, for the meal log / recents. Optional, defaults nil.
    var name: String? = nil
    /// AI's advisory total dose in units (nil when no live context was provided).
    var advisoryDose: Decimal? = nil

    static var zero: NutritionTotals {
        NutritionTotals(
            carbs: 0, fat: 0, protein: 0, calories: 0,
            sugar: 0, fiber: 0, netCarbs: 0,
            fpu: 0, fpuAbsorptionHours: 0,
            speed: .medium, confidence: .medium,
            superBolusRecommendation: .no, superBolusReason: ""
        )
    }

    static func from(_ foods: [DetectedFood]) -> NutritionTotals {
        let activeFoods = foods.filter { !$0.isRemoved }
        return NutritionTotals(
            carbs: activeFoods.reduce(0) { $0 + $1.carbs },
            fat: activeFoods.reduce(0) { $0 + $1.fat },
            protein: activeFoods.reduce(0) { $0 + $1.protein },
            calories: activeFoods.reduce(0) { $0 + $1.calories },
            sugar: activeFoods.reduce(0) { $0 + $1.sugar },
            fiber: activeFoods.reduce(0) { $0 + $1.fiber },
            netCarbs: activeFoods.reduce(0) { $0 + $1.carbs - $1.fiber },
            fpu: 0, fpuAbsorptionHours: 0,
            speed: .medium, confidence: .medium,
            superBolusRecommendation: .no, superBolusReason: ""
        )
    }
}

// MARK: - Chat Message

enum ChatRole: String, Codable {
    case user
    case assistant
}

struct ChatMessage: Identifiable, Codable {
    let id: UUID
    let role: ChatRole
    var text: String
    let timestamp: Date
    var updatedTotals: NutritionTotals?

    init(role: ChatRole, text: String, updatedTotals: NutritionTotals? = nil) {
        self.id = UUID()
        self.role = role
        self.text = text
        self.timestamp = Date()
        self.updatedTotals = updatedTotals
    }
}
