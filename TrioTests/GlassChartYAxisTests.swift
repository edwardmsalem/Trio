import Foundation
import Testing
@testable import Trio

/// The glass Home chart used to stop at 240 mg/dL whatever the data. The axis must
/// grow with the readings, stay clean, and never clip a low.
@Suite("Glass chart Y axis") struct GlassChartYAxisTests {
    private func axis(_ readings: [Double], low: Double = 70, high: Double = 180, units: GlucoseUnits = .mgdL)
        -> GlassChartYAxis
    {
        GlassChartYAxis.make(readingsMgdL: readings, lowMgdL: low, highMgdL: high, units: units)
    }

    @Test("In-range day keeps the old 40...240 look") func inRangeKeepsOldLook() {
        let a = axis([95, 120, 160])
        #expect(a.domain == 40 ... 240)
        #expect(a.gridlines == [100, 150, 200])
    }

    @Test("No readings still shows the default axis") func emptyReadings() {
        #expect(axis([]).domain == 40 ... 240)
    }

    @Test("Highs raise the top to the next clean gridline") func highsRaiseTop() {
        #expect(axis([120, 230]).domain.upperBound == 290)
        #expect(axis([120, 230]).gridlines == [100, 150, 200, 250])
        #expect(axis([120, 260]).domain.upperBound == 340)
        #expect(axis([120, 260]).gridlines == [100, 200, 300])
        #expect(axis([120, 340]).domain.upperBound == 440)
        #expect(axis([120, 340]).gridlines == [100, 200, 300, 400])
    }

    @Test("Every reading fits inside the domain") func readingsFit() {
        for peak in stride(from: 150.0, through: 400, by: 5) {
            #expect(axis([100, peak]).domain.contains(peak))
        }
    }

    @Test("Top is capped at the sensor ceiling") func capped() {
        let a = axis([120, 401, 450])
        #expect(a.domain.upperBound == 440)
        #expect(a.gridlines.last == 400)
    }

    @Test("A high target above 200 stays on the chart") func highTargetIncluded() {
        #expect(axis([100, 120], high: 220).domain.upperBound == 290)
    }

    @Test("Lows below 40 lower the bottom so they are not clipped") func lowsNotClipped() {
        #expect(axis([39, 120]).domain.lowerBound == 30)
        #expect(axis([39, 120]).domain.contains(39))
        #expect(axis([54, 120]).domain.lowerBound == 40)
        #expect(axis([120], low: 35).domain.contains(35))
    }

    @Test("mmol/L uses clean mmol gridlines and fits highs") func mmol() {
        let calm = axis([95, 120, 160], units: .mmolL)
        #expect(calm.gridlines == [6, 8, 10, 12])
        #expect(abs(calm.domain.upperBound - 14.2) < 0.001)

        let high = axis([120, 340], units: .mmolL)
        #expect(high.gridlines == [8, 12, 16, 20])
        #expect(high.domain.contains(340 * 0.0555))

        let capped = axis([120, 450], units: .mmolL)
        #expect(capped.gridlines.last == 24)
        #expect(capped.domain.contains(400 * 0.0555))

        let low = axis([39, 120], units: .mmolL)
        #expect(low.domain.contains(39 * 0.0555))
    }
}
