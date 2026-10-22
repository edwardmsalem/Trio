import Foundation

struct DeterminationData {
    let cob: Int
    let tdd: Decimal
    let eventualBG: Int?
    let target: Decimal
    let date: Date?
    let minForecast: [Int]
    let maxForecast: [Int]
    let forecastLines: [(type: String, values: [Int])]
}
