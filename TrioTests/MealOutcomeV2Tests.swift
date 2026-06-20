import Foundation
import Testing

@testable import Trio

@Suite("MealOutcome v2 decode-safety") struct MealOutcomeV2Tests {
    // A LoggedMeal blob written by the v1 build: its `outcome` has only the
    // original five fields and no curve / insulin / cob. It must still decode,
    // with the v2 fields coming back nil.
    private let legacyMealJSON = """
    {
      "id": "11111111-1111-1111-1111-111111111111",
      "date": 706000000,
      "name": "Kibbeh dinner",
      "carbs": 73,
      "fat": 28,
      "protein": 26,
      "source": "plate",
      "outcome": {
        "startBG": 110,
        "peakBG": 188,
        "peakMinutes": 75,
        "endBG": 132,
        "computedAt": 706010800
      }
    }
    """

    @Test("legacy meal with old-shape outcome still decodes; v2 fields are nil") func legacyDecodes() throws {
        let data = Data(legacyMealJSON.utf8)
        let meal = try JSONDecoder().decode(LoggedMeal.self, from: data)
        #expect(meal.name == "Kibbeh dinner")
        let outcome = try #require(meal.outcome)
        #expect(outcome.peakBG == 188)
        #expect(outcome.curve == nil)
        #expect(outcome.insulinDelivered == nil)
        #expect(outcome.cobAtStart == nil)
    }

    @Test("v2 outcome round-trips curve, insulin, and cob") func v2RoundTrips() throws {
        let outcome = MealOutcome(
            startBG: 110,
            peakBG: 188,
            peakMinutes: 75,
            endBG: 132,
            computedAt: Date(timeIntervalSince1970: 706_010_800),
            curve: [CurvePoint(minutesFromStart: 0, glucose: 110), CurvePoint(minutesFromStart: 75, glucose: 188)],
            insulinDelivered: Decimal(string: "8.5"),
            cobAtStart: 12
        )
        let encoded = try JSONEncoder().encode(outcome)
        let decoded = try JSONDecoder().decode(MealOutcome.self, from: encoded)
        #expect(decoded.curve?.count == 2)
        #expect(decoded.curve?.last?.glucose == 188)
        #expect(decoded.insulinDelivered == Decimal(string: "8.5"))
        #expect(decoded.cobAtStart == 12)
    }
}
