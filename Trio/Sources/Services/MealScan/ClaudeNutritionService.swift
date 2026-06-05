import Foundation
import UIKit

protocol ClaudeNutritionService {
    /// Codex thread id for the active chat. Persisted by MealChatSession so a
    /// conversation can resume after the app is backgrounded or killed.
    var activeThreadId: String? { get set }
    func startSession(image: UIImage, detectedFoods: [DetectedFood], customFoodNotes: [(dish: String, note: String)]) async throws -> AsyncStream<String>
    func sendMessage(_ text: String) async throws -> AsyncStream<String>
    func resetSession()
    func parseNutritionLabel(image: UIImage) async throws -> NutritionLabelData
    func startFreeFormChat(initialMessage: String, image: UIImage?, contextBlock: String?) async throws -> AsyncStream<String>
}

struct NutritionLabelData {
    let dish: String
    let servingDescription: String
    let carbs: Decimal
    let fat: Decimal
    let protein: Decimal
    let calories: Decimal
    let sugar: Decimal
    let fiber: Decimal
    let netCarbs: Decimal
}

// MARK: - Codex Proxy Implementation
//
// This used to call Anthropic directly. It now calls codex-proxy
// (Mac-mini service backed by Eddie's ChatGPT subscription via the Codex SDK).
// The class name is kept as BaseClaudeNutritionService for assembly-binding stability —
// rename if/when the protocol is also renamed.

final class BaseClaudeNutritionService: ClaudeNutritionService, Injectable {
    private let proxyURL: String
    private let proxySecret: String

    /// Codex thread ID for the active chat session. nil = no active session.
    var activeThreadId: String?
    private var systemPromptForFirstTurn: String?

    // swiftlint:disable line_length
    private let systemPrompt = """
    You are an expert nutritionist and food analyst helping a person with Type 1 Diabetes estimate carbohydrates, fat, and protein for insulin dosing via an insulin pump (Trio/OpenAPS). Accuracy directly affects their health. Overestimating carbs causes low blood sugar (dangerous). Underestimating causes high blood sugar (harmful). When uncertain, err slightly high on carbs and always give a number — never refuse to estimate.

    ## YOUR INPUTS
    At the start of every session you receive:
    1. A photo of the meal (possibly multiple angles)
    2. A structured FatSecret scan — a list of DetectedFood items, each with:
       - `name` and `nameSingular` — the identified food
       - `foodType` — either "Brand" or "Generic"
       - `portionGrams` — FatSecret's visual portion estimate
       - `servingDescription` — how FatSecret describes the serving
       - `carbs`, `fat`, `protein`, `calories`, `sugar`, `fiber`
       - `alternativeServings` — other serving size options from the database

    FatSecret has no confidence score. It never tells you how certain it is. Treat every detection as a starting point requiring your visual verification, not an authoritative answer.

    ## HOW TO INTERPRET FATSECRET DATA
    **foodType: "Brand"** — FatSecret matched a specific branded product. Nutrition values come directly from the product label. Accept these macros as reliable. Your job is to verify the portion only — does the amount in the photo match what FatSecret estimated?

    **foodType: "Generic"** — FatSecret matched a generic database entry. Nutrition values are averages. The identification may be correct but preparation method, sauce, and portion are all unknown. Ask about preparation. Challenge the portion visually.

    **When to override FatSecret nutrition entirely:** If you recognize the item as a Syrian Jewish (SY) dish — regardless of what FatSecret called it — discard FatSecret's nutrition estimate and calculate from scratch using the SY reference table below. FatSecret is not trained on SY cuisine and its estimates for these dishes are unreliable.

    **When to trust FatSecret nutrition:** Standard Western foods with foodType "Brand" (packaged yogurt, granola bars, labeled products) — accept macros, verify portion only. Standard Western foods with foodType "Generic" (grilled chicken, salad, fruit) — use as baseline, verify portion and preparation.

    **Sugar and fiber:** Always review the `sugar` field — high sugar indicates fast glycemic impact. Always review the `fiber` field — subtract fiber from total carbs to get net carbs for dosing. Note both in your analysis.

    ## SY DISH REFERENCE TABLE
    Use these defaults when you identify a dish as SY cuisine. State your assumption and ask the user to confirm size if uncertain.

    | Dish | Default carbs | Key variable | Notes |
    |------|--------------|--------------|-------|
    | Kibbeh (torpedo, fried) | 18g per piece | Piece size | Based on ~85g piece, bulgur shell. Smaller pieces (AFIA size ~64g) run ~13g |
    | Sambousak (cheese, baked) | 10g per piece | Dough thickness | Half-moon, sesame coated, ~40g per piece |
    | Sambousak (meat, fried) | 18g per piece | Dough thickness | Larger, ~60g per piece. Always confirm filling — cheese vs. meat changes carbs significantly |
    | Lachmagine (mini, 3-4 inch) | 12g per piece | Dough thickness | Includes ~2-3g from tamarind topping. People typically eat 3-5 pieces (36-60g total) |
    | Hamod/hamud soup (1 cup) | 27g per cup | Rice addition | Includes 3 rice-flour kibbeh balls (~3g each). Add 22g if served over rice — always ask |
    | Challah | 30g per slice | Slice thickness | Estimate by thickness relative to standard loaf |
    | Syrian flatbread (khubz) | 32g per piece | Size | Full round piece |
    | Hummus | 8g per oz | Portion size | Estimate by coverage area |
    | Baba ghanoush | 2-3g per oz | Portion size | Low carb, eggplant base |
    | Adjwe (semolina date cookie) | 18g per piece | Size | Semolina + dates, estimate by diameter |
    | Baklawa | 15g per piece | Syrup saturation | Phyllo + sugar syrup + nuts. Ask about syrup level |
    | Dates | 18g each | Count | Always ask exact count |
    | Figs | 10g each | Count | Fresh or dried — confirm |

    **Tamarind (oot):** A signature SY ingredient appearing in sauces on lachmagine, mechshi, roast meats, and more. Contributes ~9g carbs per tablespoon of paste. Always ask about tamarind-based sauces.

    ## INGREDIENT CARB RATES
    Use these when calculating from scratch for unrecognized or SY items:

    | Ingredient | Rate |
    |-----------|------|
    | Bulgur wheat (cooked) | 8.5g per oz |
    | Flour dough (wheat, raw) | 18-20g per oz |
    | Semolina (dry) | 20g per oz |
    | Phyllo/filo pastry | 17g per oz |
    | Tamarind paste/oot | 9g per tbsp |
    | Pomegranate molasses | 8-10g per tbsp |
    | Honey | 17g per tbsp |
    | Brown sugar | 13g per tbsp |
    | Ketchup | 4g per tbsp |
    | Apricot jam/preserves | 13g per tbsp |
    | Date syrup (silan) | 15g per tbsp |
    | Chickpeas (cooked) | 8g per oz |
    | Lentils (cooked) | 5.5g per oz |
    | White rice (cooked) | 10g per oz |
    | Potato | 5g per oz |

    ## REASONING APPROACH
    For every item, estimate by ingredient and size — not by fixed "per piece" values. Show your work:
    1. Identify the carb-contributing ingredient (dough, bulgur shell, sauce, etc.)
    2. State your size assumption explicitly so the user can correct it: "I'm estimating each kibbeh at about 3 inches — does that look right?"
    3. Use the plate, utensils, hands, or other items in the photo for scale. A standard dinner plate is 10-11 inches. A salad plate is 7-8 inches.
    4. Calculate from the rates above and show the math: "Bulgur shell ~1.5oz x 8.5g/oz = ~13g carbs per piece x 3 pieces = 39g"
    5. When FatSecret's portion differs from your visual estimate, flag it: "FatSecret estimated 158g (1 cup) — visually this looks closer to 200g to me. Can you confirm?"

    ## USER PROFILE
    - Syrian Jewish (SY) community, Brooklyn
    - Does not eat rice — default to NOT counting rice unless user explicitly confirms they ate it
    - Typically removes potatoes from dishes — confirm before counting
    - Main carb sources: mazza shells (bulgur, dough), challah/bread, sauces on meat, desserts
    - FatSecret has been pre-seeded with common SY dishes via `eaten_foods` — a correct SY ID from FatSecret is more likely than baseline accuracy suggests, but still verify with the user

    ## SHABBAT DINNER CONTEXT
    If the meal appears to be a Shabbat/Friday night dinner, anticipate a multi-course structure:

    **Mazza (appetizers):** Kibbeh, sambousak, lachmagine, hummus, baba ghanoush. Mazza alone can total 60-100g+ carbs. Always ask how many pieces of each item were eaten.

    **Soup:** Hamod/hamud — lemony broth with meatballs. Broth is low carb (~3-5g per bowl). Watch for kibbeh balls in the soup (rice flour shell, ~3g each), carrots (~6-8g per medium carrot), and potatoes (user removes — confirm).

    **Roast/main:** Meat is ~0g carbs. The sauce is where carbs hide. If meat looks dark, shiny, sticky, or glazed — ask about the sauce. Ask about roast sauce every single time. Common sauces: tamarind/oot (~9g per tbsp), apricot-based, pomegranate molasses (~8-10g per tbsp), honey glaze (~17g per tbsp).

    **Desserts:** See SY reference table above. Always ask exact count on dates and figs.

    ## CONVERSATION RULES
    - Start every session by listing every item you can identify in the photo, then flag anything you cannot identify before asking questions
    - Ask no more than 3 questions per response
    - When the user provides new information, show the delta explicitly: "+12g carbs from honey glaze → new total: 58g"
    - Never say "I can't determine" — always give a best estimate with a confidence note
    - If uncertain, give a range and recommend the higher end for dosing
    - High-fat meals delay all carb absorption — always note this when fat content is significant

    ## ABSORPTION SPEED
    Flag each major carb source:
    - **FAST** (spike within 15-30 min): white bread/challah, sugar syrups, honey, juice, dates, high-sugar items
    - **MEDIUM** (30-60 min): flour dough (sambousak, lachmagine), semolina
    - **SLOW** (60-90 min): bulgur (kibbeh shells), lentils, chickpeas, whole grains
    - **HIGH FAT modifier**: high fat meals delay all absorption regardless of carb type — note when fat is high

    Use MIXED when multiple speed categories are present in the same meal.

    ## SUPER BOLUS RECOMMENDATION
    A super bolus front-loads basal insulin into the meal bolus. The user adds roughly 1 hour of their basal rate to the upfront bolus, then suspends basal for that same period. Total insulin delivered is unchanged — only the timing changes. This crushes fast glucose spikes before they start.

    Recommend it aggressively. Calculate sugar as a percentage of total carbs: (sugar / carbs) x 100
    - **YES** — if sugar is 25%+ of total carbs, OR SPEED is FAST, OR the meal contains any high-GI items (challah, dates, honey glaze, sugar syrup, baklawa, juice, adjwe, atayef)
    - **CONSIDER** — if sugar is 15-24% of total carbs, OR SPEED is MIXED with at least one FAST item present
    - **NO** — pure SLOW or MEDIUM meals with sugar below 15% of total carbs

    ## FPU CALCULATION
    After finalizing macros, calculate Fat Protein Units for the pump's extended bolus:

    **Formula:** FPU = (fat grams x 9 + protein grams x 4) / 100

    **Absorption durations (Warsaw Method):**
    - 1 FPU -> 3 hours
    - 2 FPU -> 4 hours
    - 3 FPU -> 5 hours
    - 4+ FPU -> 8 hours

    Note: Trio applies a default Override Factor of 0.5, meaning only 50% of FPU carb equivalents are entered into the system. Trio delivers insulin dynamically via SMBs and temp basals — not as a fixed extended bolus. Actual behavior depends on the user's configured delay, max duration, and interval settings.

    ## OUTPUT BLOCK — MACHINE-READ, DO NOT MODIFY FORMAT
    The nutrition block is parsed programmatically and drives insulin dosing decisions directly. Every response must end with this block. No exceptions. No text after it. No format changes.

    ```nutrition
    NAME: <short dish name, 2-4 words, e.g. "Kibbeh dinner" or "Chicken & rice">
    CARBS: <number>g
    FAT: <number>g
    PROTEIN: <number>g
    CALORIES: <number>
    SUGAR: <number>g
    FIBER: <number>g
    NET_CARBS: <number>g
    FPU: <number> (absorption: <duration>)
    SPEED: <FAST/MEDIUM/SLOW/MIXED>
    SUPER_BOLUS: <YES/CONSIDER/NO> (<one sentence reason>)
    CONFIDENCE: <HIGH/MEDIUM/LOW>
    ```

    NET_CARBS = CARBS minus FIBER. This is the value most relevant for bolus calculation.

    ## SYRIAN-JEWISH FOOD DATABASE (authoritative)
    A structured SY food database is attached at the end of this prompt as JSON. For ANY Syrian-Jewish dish, use the database's carb values over general nutrition knowledge. Homemade SY dishes carry about 30% variability, so state your assumption and let the user correct. Prefer weight-based estimates; per-piece values are fallbacks.

    ## MANDATORY CLARIFICATIONS
    These dishes swing too much to guess. Ask before giving a carb count:

    | Dish | Ask | Swing |
    |------|-----|-------|
    | Hamod soup | Broth only / rice in soup / over rice bed | 8g / 20g / 55g |
    | Ka'ak | Cookie vs bread ring | 10g vs 55g |
    | Atayef | Plain vs fried + syrup | 6g vs 30g |
    | Fattoush | Light vs heavy pita chips | 8g vs 20g |
    | Glazed meat | Which sauce? | +9 to 17g per tbsp |
    | Any dish | Over rice? | +30 to 45g |

    ## SUGGESTED DOSE (advisory only)
    The user runs Trio, a closed-loop pump. Trio's own bolus calculator computes the dose that actually gets delivered. Your suggested dose is a second opinion for sanity-checking, never an instruction to inject on top of Trio.

    When the CURRENT STATE block (glucose, IOB, ISF, CR, target) is present, compute an advisory dose and show your math in prose BEFORE the nutrition block:

    1. Meal = net carbs / CR
    2. Apply the ISF tier to ISF based on current glucose:
       - BG under 70: ISF x 1.2 (gentler)
       - BG 70 to 140: ISF x 1.0
       - BG 140 to 200: ISF x 0.9
       - BG 200 to 250: ISF x 0.8
       - BG over 250: ISF x 0.7 (most aggressive)
    3. Correction = (glucose - target) / tiered_ISF
    4. Subtract IOB from the TOTAL (meal + correction), not just the correction
    5. Note trend: if rising, the meal may need pre-bolusing sooner; if falling, be cautious

    Present it like:
    "Advisory dose (Trio decides the real number): meal 73/7 = 10.4u + correction (165-100)/31.5 = 2.1u - IOB 1.2u = ~11.3u. Heads up: above a 10u single bolus, consider splitting."

    Flag automatically: stacking (recent insulin + more), bolusing while below target, and BG over 250 (check ketones).

    ## PRE-BOLUS TIMING
    - FAST / high-GI (challah, syrup, honey, juice, dates): pre-bolus 15 to 25 min, more if BG is already high
    - MEDIUM (dough: sambousak, lachmagine): pre-bolus 10 to 15 min
    - SLOW (bulgur kibbeh, lentils, chickpeas): little or no pre-bolus
    - High fat delays everything: spread the dose or lean on FPU
    """
    // swiftlint:enable line_length

    init() {
        self.proxyURL = MealScanDevKeys.codexProxyURL
        self.proxySecret = MealScanDevKeys.codexProxySecret
    }

    /// Base prompt plus the bundled SY food database, loaded once.
    private lazy var composedSystemPrompt: String = {
        guard let url = Bundle.main.url(forResource: "sy_food_database", withExtension: "json"),
              let json = try? String(contentsOf: url, encoding: .utf8)
        else {
            return systemPrompt
        }
        return systemPrompt + "\n\n## SY_FOOD_DATABASE (JSON)\n```json\n" + json + "\n```"
    }()

    // MARK: - Public

    func startSession(
        image: UIImage,
        detectedFoods: [DetectedFood],
        customFoodNotes: [(dish: String, note: String)]
    ) async throws -> AsyncStream<String> {
        let foodSummary = formatDetectedFoods(detectedFoods)
        let customNotesText = Self.formatCustomNotes(customFoodNotes)

        let userText = """
        Current date/time: \(Self.formattedCurrentDate())

        Initial food scan detected the following items:

        \(foodSummary)
        \(customNotesText)

        Please review the photo and the scan results. Let me know if anything looks off \
        or if you notice foods that weren't detected. I'll tell you about any hidden \
        ingredients or corrections.
        """

        // Start a fresh thread on the proxy
        activeThreadId = nil
        systemPromptForFirstTurn = composedSystemPrompt

        return try await streamChat(
            userText: userText,
            image: image,
            includeSystem: true
        )
    }

    func sendMessage(_ text: String) async throws -> AsyncStream<String> {
        try await streamChat(userText: text, image: nil, includeSystem: false)
    }

    func resetSession() {
        activeThreadId = nil
        systemPromptForFirstTurn = nil
    }

    func parseNutritionLabel(image: UIImage) async throws -> NutritionLabelData {
        let imageBase64 = prepareImage(image)

        var request = URLRequest(url: try buildURL("/label-parse"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(proxySecret)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60

        let body: [String: Any] = [
            "image_base64": imageBase64,
            "mime": "image/jpeg"
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, (200 ... 299).contains(httpResponse.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw ClaudeNutritionError.apiError(statusCode: code)
        }

        guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClaudeNutritionError.parseError
        }

        let dish = (payload["dish"] as? String) ?? ""
        guard !dish.isEmpty else { throw ClaudeNutritionError.parseError }

        return NutritionLabelData(
            dish: String(dish.prefix(25)),
            servingDescription: (payload["serving_description"] as? String) ?? "",
            carbs: Self.decimal(payload["carbs"]),
            fat: Self.decimal(payload["fat"]),
            protein: Self.decimal(payload["protein"]),
            calories: Self.decimal(payload["calories"]),
            sugar: Self.decimal(payload["sugar"]),
            fiber: Self.decimal(payload["fiber"]),
            netCarbs: Self.decimal(payload["net_carbs"])
        )
    }

    func startFreeFormChat(initialMessage: String, image: UIImage?, contextBlock: String?) async throws -> AsyncStream<String> {
        activeThreadId = nil
        systemPromptForFirstTurn = composedSystemPrompt

        let text = initialMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = text.isEmpty
            ? "Please analyze this meal photo. List what you see, ask any clarifying questions, and provide your best nutrition estimate."
            : text

        var userText = "Current date/time: \(Self.formattedCurrentDate())"
        if let contextBlock, !contextBlock.isEmpty {
            userText += "\n\n\(contextBlock)"
        }
        userText += "\n\n\(base)"

        return try await streamChat(
            userText: userText,
            image: image,
            includeSystem: true
        )
    }

    // MARK: - Streaming core

    private func streamChat(userText: String, image: UIImage?, includeSystem: Bool) async throws -> AsyncStream<String> {
        var request = URLRequest(url: try buildURL("/chat"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(proxySecret)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120

        var body: [String: Any] = [
            "messages": [["role": "user", "content": userText]]
        ]
        if includeSystem, let sys = systemPromptForFirstTurn {
            body["system"] = sys
        }
        if let tid = activeThreadId {
            body["thread_id"] = tid
        }
        if let image {
            body["image_base64"] = prepareImage(image)
            body["mime"] = "image/jpeg"
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse, (200 ... 299).contains(httpResponse.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw ClaudeNutritionError.apiError(statusCode: code)
        }

        return AsyncStream { continuation in
            Task {
                do {
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data: ") else { continue }
                        let jsonString = String(line.dropFirst(6))
                        guard let jsonData = jsonString.data(using: .utf8),
                              let event = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
                        else { continue }

                        let type = event["type"] as? String ?? ""

                        switch type {
                        case "text_delta":
                            if let text = event["text"] as? String, !text.isEmpty {
                                continuation.yield(text)
                            }
                        case "item_completed":
                            if let text = event["text"] as? String, !text.isEmpty {
                                continuation.yield(text)
                            }
                        case "done":
                            if let tid = event["thread_id"] as? String {
                                await MainActor.run { self.activeThreadId = tid }
                            }
                            await MainActor.run { self.systemPromptForFirstTurn = nil }
                            continuation.finish()
                            return
                        case "error":
                            let msg = event["message"] as? String ?? "stream error"
                            debug(.default, "[codex-proxy] error: \(msg)")
                            continuation.finish()
                            return
                        default:
                            continue
                        }
                    }
                    continuation.finish()
                } catch {
                    debug(.default, "[codex-proxy] stream failed: \(error.localizedDescription)")
                    continuation.finish()
                }
            }
        }
    }

    // MARK: - Helpers

    private func buildURL(_ path: String) throws -> URL {
        let base = proxyURL.hasSuffix("/") ? String(proxyURL.dropLast()) : proxyURL
        guard let url = URL(string: base + path) else {
            throw ClaudeNutritionError.apiError(statusCode: -1)
        }
        return url
    }

    private func prepareImage(_ image: UIImage) -> String {
        let maxDimension: CGFloat = 1568
        let scale = min(maxDimension / image.size.width, maxDimension / image.size.height, 1.0)
        let newSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)

        let renderer = UIGraphicsImageRenderer(size: newSize)
        let resized = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }

        let jpegData = resized.jpegData(compressionQuality: 0.85) ?? Data()
        return jpegData.base64EncodedString()
    }

    private func formatDetectedFoods(_ foods: [DetectedFood]) -> String {
        foods.enumerated().map { index, food in
            let serving = food.servingDescription.isEmpty ? "\(food.portionGrams)g" : food.servingDescription
            let singular = food.nameSingular.isEmpty ? "" : " (\(food.nameSingular))"
            var lines = """
            \(index + 1). \(food.name)\(singular)
               Type: \(food.foodType) | Serving: \(serving) | Portion: \(food.portionGrams)g
               Carbs: \(food.carbs)g | Fat: \(food.fat)g | Protein: \(food.protein)g | Cal: \(food.calories)
               Sugar: \(food.sugar)g | Fiber: \(food.fiber)g
            """

            let topServings = food.alternativeServings.prefix(3)
            if !topServings.isEmpty {
                let servingList = topServings.map { "\($0.description) (\($0.metricAmount)g)" }.joined(separator: ", ")
                lines += "\n   Alt servings: \(servingList)"
            }

            return lines
        }.joined(separator: "\n\n")
    }

    private static func formattedCurrentDate() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, MMMM d, yyyy h:mm a"
        formatter.locale = Locale(identifier: "en_US")
        return formatter.string(from: Date())
    }

    private static func formatCustomNotes(_ notes: [(dish: String, note: String)]) -> String {
        guard !notes.isEmpty else { return "" }
        let formatted = notes.map { "- \($0.dish): USER NOTE: \($0.note)" }.joined(separator: "\n")
        return "\nUser-provided food notes (apply when these foods are identified):\n\(formatted)"
    }

    private static func decimal(_ any: Any?) -> Decimal {
        if let n = any as? NSNumber {
            return n.decimalValue
        }
        if let s = any as? String, let d = Decimal(string: s) {
            return d
        }
        return 0
    }
}

// MARK: - Totals Parsing
// (parseTotals is consumed by StandaloneChatView/MealScanStateModel to extract
//  the structured nutrition block out of streaming assistant text. Unchanged.)

extension BaseClaudeNutritionService {
    static func parseTotals(from text: String) -> NutritionTotals? {
        guard let range = text.range(of: "```nutrition\n", options: .backwards),
              let endRange = text.range(of: "```", options: .backwards, range: range.upperBound ..< text.endIndex)
        else {
            return nil
        }

        let block = String(text[range.upperBound ..< endRange.lowerBound])
        var carbs: Decimal?
        var fat: Decimal?
        var protein: Decimal?
        var calories: Decimal?
        var sugar: Decimal = 0
        var fiber: Decimal = 0
        var netCarbs: Decimal = 0
        var fpu: Decimal = 0
        var fpuAbsorptionHours: Decimal = 0
        var speed: MealSpeed = .medium
        var confidence: ConfidenceLevel = .medium
        var superBolusRecommendation: SuperBolusRecommendation = .no
        var superBolusReason: String = ""
        var name: String?

        for line in block.components(separatedBy: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces).uppercased()
            let rawValue = parts[1].trimmingCharacters(in: .whitespaces)
            let numericValue = Decimal(string: rawValue.trimmingCharacters(in: .letters))

            switch key {
            case "NAME": name = rawValue.isEmpty ? nil : String(rawValue.prefix(40))
            case "CARBS": carbs = numericValue
            case "FAT": fat = numericValue
            case "PROTEIN": protein = numericValue
            case "CALORIES": calories = numericValue
            case "SUGAR": sugar = numericValue ?? 0
            case "FIBER": fiber = numericValue ?? 0
            case "NET_CARBS": netCarbs = numericValue ?? 0
            case "FPU":
                let parsed = parseFPU(rawValue)
                fpu = parsed.fpu
                fpuAbsorptionHours = parsed.absorptionHours
            case "SPEED":
                speed = MealSpeed(rawValue: rawValue.lowercased()) ?? .medium
            case "CONFIDENCE":
                confidence = ConfidenceLevel(rawValue: rawValue.lowercased()) ?? .medium
            case "SUPER_BOLUS":
                let parsed = parseSuperBolus(rawValue)
                superBolusRecommendation = parsed.recommendation
                superBolusReason = parsed.reason
            default: break
            }
        }

        guard let c = carbs, let f = fat, let p = protein, let cal = calories else {
            return nil
        }

        return NutritionTotals(
            carbs: c,
            fat: f,
            protein: p,
            calories: cal,
            sugar: sugar,
            fiber: fiber,
            netCarbs: netCarbs,
            fpu: fpu,
            fpuAbsorptionHours: fpuAbsorptionHours,
            speed: speed,
            confidence: confidence,
            superBolusRecommendation: superBolusRecommendation,
            superBolusReason: superBolusReason,
            name: name
        )
    }

    private static func parseFPU(_ raw: String) -> (fpu: Decimal, absorptionHours: Decimal) {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)

        if let parenStart = trimmed.firstIndex(of: "(") {
            let fpuString = String(trimmed[trimmed.startIndex ..< parenStart])
                .trimmingCharacters(in: .whitespaces)
            let fpuValue = Decimal(string: fpuString) ?? 0

            let parenContent = String(trimmed[parenStart...])
            var hoursString = ""
            var foundDigit = false
            for char in parenContent {
                if char.isNumber || (char == "." && foundDigit) {
                    hoursString.append(char)
                    foundDigit = true
                } else if foundDigit {
                    break
                }
            }
            let hours = Decimal(string: hoursString) ?? 0

            return (fpuValue, hours)
        } else {
            let fpuValue = Decimal(string: trimmed.trimmingCharacters(in: .letters)) ?? 0
            return (fpuValue, 0)
        }
    }

    private static func parseSuperBolus(_ raw: String) -> (recommendation: SuperBolusRecommendation, reason: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)

        let keyword: String
        let reason: String

        if let parenStart = trimmed.firstIndex(of: "("),
           let parenEnd = trimmed.lastIndex(of: ")")
        {
            keyword = String(trimmed[trimmed.startIndex ..< parenStart]).trimmingCharacters(in: .whitespaces)
            let reasonStart = trimmed.index(after: parenStart)
            reason = String(trimmed[reasonStart ..< parenEnd]).trimmingCharacters(in: .whitespaces)
        } else {
            keyword = trimmed
            reason = ""
        }

        let recommendation: SuperBolusRecommendation
        switch keyword.uppercased() {
        case "YES": recommendation = .yes
        case "CONSIDER": recommendation = .consider
        default: recommendation = .no
        }

        return (recommendation, reason)
    }
}

// MARK: - Error Types

enum ClaudeNutritionError: LocalizedError {
    case apiError(statusCode: Int)
    case streamingFailed
    case parseError

    var errorDescription: String? {
        switch self {
        case .apiError(let code): return "Codex proxy error (code: \(code))"
        case .streamingFailed: return "Failed to stream response from Codex proxy"
        case .parseError: return "Couldn't read the nutrition label clearly. Try again with better lighting or a closer shot."
        }
    }
}
