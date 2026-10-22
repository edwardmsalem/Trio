import Foundation

/// Vertical axis for the glass Home glucose chart.
///
/// The chart used to be pinned to 40...240 mg/dL with labels at 100/150/200, so any
/// reading above ~240 ran off the top. This fits the axis to what is drawn: the visible
/// readings and the target band, rounded up to a clean gridline, never below the old
/// 200 top and never past the sensor's 400 mg/dL ceiling. The bottom stays at 40 mg/dL
/// unless a reading (or the low target) sits below it.
///
/// Inputs are mg/dL (how readings and targets are stored). Output is in display units.
struct GlassChartYAxis: Equatable {
    let domain: ClosedRange<Double>
    let gridlines: [Double]

    static let sensorMaxMgdL: Double = 400
    static let defaultBottomMgdL: Double = 40

    static func make(
        readingsMgdL: [Double],
        lowMgdL: Double,
        highMgdL: Double,
        units: GlucoseUnits
    ) -> GlassChartYAxis {
        let peak = min(max(readingsMgdL.max() ?? 0, highMgdL), sensorMaxMgdL)
        let trough = min(readingsMgdL.min() ?? defaultBottomMgdL, lowMgdL)
        switch units {
        case .mgdL: return mgdL(peak: peak, trough: trough)
        case .mmolL: return mmolL(peak: peak * rate, trough: trough * rate)
        }
    }

    private static let rate = Double(truncating: GlucoseUnits.exchangeRate as NSNumber)

    private static func mgdL(peak: Double, trough: Double) -> GlassChartYAxis {
        // 200 / 250, then whole hundreds (300 / 400) so the labels stay sparse.
        var top = max(200, (peak / 50).rounded(.up) * 50)
        if top > 250 { top = (top / 100).rounded(.up) * 100 }
        let step: Double = top <= 250 ? 50 : 100
        let bottom = trough >= defaultBottomMgdL
            ? defaultBottomMgdL
            : max(20, ((trough - 5) / 10).rounded(.down) * 10)
        return GlassChartYAxis(
            domain: bottom ... top + 40,
            gridlines: Array(stride(from: 100, through: top, by: step))
        )
    }

    private static func mmolL(peak: Double, trough: Double) -> GlassChartYAxis {
        // 12 / 14 in steps of 2, then 16 / 20 / 24 in steps of 4.
        let top = peak <= 14
            ? max(12, (peak / 2).rounded(.up) * 2)
            : (peak / 4).rounded(.up) * 4
        let step: Double = top <= 14 ? 2 : 4
        let defaultBottom = defaultBottomMgdL * rate
        let bottom = trough >= defaultBottom
            ? defaultBottom
            : max(1, ((trough - 0.3) * 2).rounded(.down) / 2)
        return GlassChartYAxis(
            domain: bottom ... top + 2.2,
            gridlines: Array(stride(from: step == 2 ? 6 : 8, through: top, by: step))
        )
    }
}
