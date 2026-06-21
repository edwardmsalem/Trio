import Foundation
import Testing

@testable import Trio

@Suite("MealScan Parsing Tests") struct MealScanParsingTests {
    // MARK: - parseTotals

    private let fullResponse = """
    Looks like 3 kibbeh and a slice of challah.

    ```nutrition
    NAME: Kibbeh dinner
    CARBS: 73g
    FAT: 28g
    PROTEIN: 26g
    CALORIES: 640
    SUGAR: 6g
    FIBER: 4g
    NET_CARBS: 69g
    FPU: 2.5 (absorption: 4h)
    SPEED: MIXED
    SUPER_BOLUS: CONSIDER (challah is high GI)
    CONFIDENCE: HIGH
    ADVISORY_DOSE: 11.3u
    ```
    """

    @Test("parses the full nutrition block") func parsesFullBlock() {
        let totals = BaseClaudeNutritionService.parseTotals(from: fullResponse)
        #expect(totals != nil)
        #expect(totals?.carbs == 73)
        #expect(totals?.fat == 28)
        #expect(totals?.protein == 26)
        #expect(totals?.netCarbs == 69)
        #expect(totals?.fpu == Decimal(string: "2.5"))
        #expect(totals?.fpuAbsorptionHours == 4)
        #expect(totals?.speed == .mixed)
        #expect(totals?.confidence == .high)
        #expect(totals?.superBolusRecommendation == .consider)
        #expect(totals?.name == "Kibbeh dinner")
        #expect(totals?.advisoryDose == Decimal(string: "11.3"))
    }

    @Test("ADVISORY_DOSE N/A parses as nil") func advisoryDoseNA() {
        let response = fullResponse.replacingOccurrences(of: "ADVISORY_DOSE: 11.3u", with: "ADVISORY_DOSE: N/A")
        let totals = BaseClaudeNutritionService.parseTotals(from: response)
        #expect(totals != nil)
        #expect(totals?.advisoryDose == nil)
    }

    @Test("missing block returns nil") func missingBlock() {
        #expect(BaseClaudeNutritionService.parseTotals(from: "just chatting, no numbers") == nil)
    }

    @Test("missing required macro returns nil") func missingMacro() {
        let response = fullResponse.replacingOccurrences(of: "CARBS: 73g\n", with: "")
        #expect(BaseClaudeNutritionService.parseTotals(from: response) == nil)
    }

    @Test("uses the LAST nutrition block in a long chat") func lastBlockWins() {
        let twoBlocks = fullResponse + "\n\nUpdated after your correction:\n\n" + fullResponse
            .replacingOccurrences(of: "CARBS: 73g", with: "CARBS: 85g")
        let totals = BaseClaudeNutritionService.parseTotals(from: twoBlocks)
        #expect(totals?.carbs == 85)
    }

    // MARK: - parseLabelBlock

    @Test("parses a label block") func parsesLabel() {
        let text = """
        ```label
        DISH: RXBAR Peanut Butter
        SERVING_SIZE: 1 bar (52g)
        CARBS: 24g
        FAT: 9g
        PROTEIN: 12g
        CALORIES: 210
        SUGAR: 13g
        FIBER: 5g
        NET_CARBS: 19g
        ```
        """
        let label = BaseClaudeNutritionService.parseLabelBlock(from: text)
        #expect(label != nil)
        #expect(label?.dish == "RXBAR Peanut Butter")
        #expect(label?.carbs == 24)
        #expect(label?.netCarbs == 19)
    }

    @Test("label net carbs derived from carbs minus fiber when absent") func labelNetCarbsDerived() {
        let text = """
        ```label
        DISH: Test Bar
        SERVING_SIZE: 1 bar
        CARBS: 30g
        FAT: 5g
        PROTEIN: 8g
        CALORIES: 200
        SUGAR: 10g
        FIBER: 6g
        NET_CARBS: 0g
        ```
        """
        let label = BaseClaudeNutritionService.parseLabelBlock(from: text)
        #expect(label?.netCarbs == 24)
    }

    // MARK: - MealContext advisory dose

    private func context(glucose: Decimal) -> MealContext {
        MealContext(
            glucose: glucose,
            deltaBG: 0,
            iob: Decimal(string: "1.2")!,
            cob: 0,
            isf: 35,
            carbRatio: 7,
            target: 100
        )
    }

    @Test("advisory dose matches the OmniBot formula") func advisoryDoseFormula() {
        // BG 165 → tier 0.9 → ISF 31.5; meal 73/7 = 10.43; corr (165-100)/31.5 = 2.06; -1.2 IOB
        let dose = context(glucose: 165).advisoryDose(netCarbs: 73)
        #expect(dose != nil)
        let value = NSDecimalNumber(decimal: dose!).doubleValue
        #expect(abs(value - 11.29) < 0.05)
    }

    @Test("ISF tier multipliers by BG range") func isfTiers() {
        #expect(context(glucose: 60).isfTierMultiplier == Decimal(string: "1.2"))
        #expect(context(glucose: 100).isfTierMultiplier == 1)
        #expect(context(glucose: 165).isfTierMultiplier == Decimal(string: "0.9"))
        #expect(context(glucose: 220).isfTierMultiplier == Decimal(string: "0.8"))
        #expect(context(glucose: 300).isfTierMultiplier == Decimal(string: "0.7"))
    }

    @Test("advisory dose nil without live data") func advisoryDoseNilWhenNoData() {
        let ctx = MealContext(glucose: 0, deltaBG: 0, iob: 0, cob: 0, isf: 0, carbRatio: 0, target: 0)
        #expect(ctx.advisoryDose(netCarbs: 50) == nil)
    }

    // MARK: - MealLog name normalization

    @Test("normalizes names for dedupe") func normalization() {
        #expect(MealLog.normalizedName("Kibbeh Dinner!") == "kibbeh dinner")
        #expect(MealLog.normalizedName("  kibbeh   DINNER ") == "kibbeh dinner")
        #expect(MealLog.normalizedName("Chicken & Rice") == "chicken rice")
    }
}
