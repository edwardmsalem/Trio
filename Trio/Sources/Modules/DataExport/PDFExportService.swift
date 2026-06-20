import CoreData
import Foundation
import UIKit

/// Produces a one-page, clinician-friendly PDF summary (time in range, GMI / est.
/// A1c, average glucose, average daily bolus, plus a daily-average trend chart)
/// for the chosen range. Read-only — mirrors `DataExportService`'s range + share
/// flow, but renders a PDF instead of CSV.
final class PDFExportService {
    private let context = CoreDataStack.shared.newTaskContext()
    private let units: GlucoseUnits

    init(units: GlucoseUnits) {
        self.units = units
    }

    struct Summary {
        var rangeLabel: String
        var startDate: Date
        var endDate: Date
        var readingCount: Int
        var dayCount: Int
        var avgGlucose: Double // mg/dL
        var gmi: Double // %
        var tirPct: Double
        var belowPct: Double
        var abovePct: Double
        var avgDailyBolus: Double // U
        var dailyAverages: [(date: Date, avg: Double)] // mg/dL per day
    }

    func generate(range: DataExportService.ExportRange) async throws -> URL {
        let summary = try await computeSummary(range: range)
        return try renderPDF(summary)
    }

    // MARK: - Stats

    private func computeSummary(range: DataExportService.ExportRange) async throws -> Summary {
        let start = range.startDate
        let end = Date()
        let calendar = Calendar.current

        return try await context.perform {
            let glucoseRequest: NSFetchRequest<GlucoseStored> = GlucoseStored.fetchRequest()
            glucoseRequest.predicate = NSPredicate(format: "date >= %@ AND date <= %@", start as NSDate, end as NSDate)
            glucoseRequest.sortDescriptors = [NSSortDescriptor(key: "date", ascending: true)]
            let readings = (try? self.context.fetch(glucoseRequest)) ?? []
            let values: [(date: Date, value: Int)] = readings.compactMap { reading in
                reading.date.map { (date: $0, value: Int(reading.glucose)) }
            }

            let count = values.count
            let avg = count > 0 ? Double(values.reduce(0) { $0 + $1.value }) / Double(count) : 0
            let gmi = count > 0 ? 3.31 + 0.02392 * avg : 0
            let inRange = values.filter { $0.value >= 70 && $0.value <= 180 }.count
            let below = values.filter { $0.value < 70 }.count
            let above = values.filter { $0.value > 180 }.count

            var byDay: [Date: (sum: Int, n: Int)] = [:]
            for point in values {
                let day = calendar.startOfDay(for: point.date)
                var entry = byDay[day] ?? (0, 0)
                entry.sum += point.value
                entry.n += 1
                byDay[day] = entry
            }
            let dailyAverages = byDay.keys.sorted().map { day in
                (date: day, avg: Double(byDay[day]!.sum) / Double(byDay[day]!.n))
            }

            let bolusRequest: NSFetchRequest<BolusStored> = BolusStored.fetchRequest()
            bolusRequest.predicate = NSPredicate(
                format: "pumpEvent.timestamp >= %@ AND pumpEvent.timestamp <= %@",
                start as NSDate,
                end as NSDate
            )
            let boluses = (try? self.context.fetch(bolusRequest)) ?? []
            let totalBolus = boluses.reduce(Decimal(0)) { $0 + (($1.amount?.decimalValue) ?? 0) }
            let dayCount = max(1, calendar.dateComponents([.day], from: start, to: end).day ?? 1)
            let avgDailyBolus = Double(truncating: totalBolus as NSNumber) / Double(dayCount)

            return Summary(
                rangeLabel: range.rawValue,
                startDate: start,
                endDate: end,
                readingCount: count,
                dayCount: dayCount,
                avgGlucose: avg,
                gmi: gmi,
                tirPct: count > 0 ? Double(inRange) / Double(count) * 100 : 0,
                belowPct: count > 0 ? Double(below) / Double(count) * 100 : 0,
                abovePct: count > 0 ? Double(above) / Double(count) * 100 : 0,
                avgDailyBolus: avgDailyBolus,
                dailyAverages: dailyAverages
            )
        }
    }

    // MARK: - Rendering

    private func glucoseText(_ mgdl: Double) -> String {
        units == .mmolL ? String(format: "%.1f", mgdl * 0.0555) : String(format: "%.0f", mgdl)
    }

    private func renderPDF(_ summary: Summary) throws -> URL {
        let pageRect = CGRect(x: 0, y: 0, width: 612, height: 792) // US Letter
        let renderer = UIGraphicsPDFRenderer(bounds: pageRect)

        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium

        let data = renderer.pdfData { ctx in
            ctx.beginPage()
            var y: CGFloat = 48

            func draw(_ text: String, font: UIFont, color: UIColor = .black, x: CGFloat = 48) {
                let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
                (text as NSString).draw(at: CGPoint(x: x, y: y), withAttributes: attrs)
            }

            draw("Trio Glucose Report", font: .boldSystemFont(ofSize: 24))
            y += 32
            draw(
                "\(summary.rangeLabel)  ·  \(dateFormatter.string(from: summary.startDate)) – \(dateFormatter.string(from: summary.endDate))",
                font: .systemFont(ofSize: 12),
                color: .darkGray
            )
            y += 18
            draw(
                "Generated \(dateFormatter.string(from: summary.endDate))  ·  \(summary.readingCount) readings over \(summary.dayCount) days",
                font: .systemFont(ofSize: 10),
                color: .gray
            )
            y += 30

            // Key metrics
            draw("Key Metrics", font: .boldSystemFont(ofSize: 15))
            y += 24
            let metrics: [(String, String)] = [
                ("Average glucose", "\(glucoseText(summary.avgGlucose)) \(units.rawValue)"),
                ("GMI (est. A1c)", String(format: "%.1f%%", summary.gmi)),
                ("Time in range (70–180)", String(format: "%.0f%%", summary.tirPct)),
                ("Time below range (<70)", String(format: "%.0f%%", summary.belowPct)),
                ("Time above range (>180)", String(format: "%.0f%%", summary.abovePct)),
                ("Average daily bolus", String(format: "%.1f U", summary.avgDailyBolus))
            ]
            for (label, value) in metrics {
                draw(label, font: .systemFont(ofSize: 12), color: .darkGray)
                let valueAttrs: [NSAttributedString.Key: Any] = [.font: UIFont.boldSystemFont(ofSize: 12)]
                (value as NSString).draw(at: CGPoint(x: 320, y: y), withAttributes: valueAttrs)
                y += 22
            }
            y += 16

            // Daily-average trend chart
            draw("Daily average glucose", font: .boldSystemFont(ofSize: 15))
            y += 24
            drawChart(summary.dailyAverages, in: CGRect(x: 48, y: y, width: 516, height: 200), context: ctx.cgContext)
            y += 220

            // Footer
            draw(
                "This report is a CGM summary for your care team. It is not medical advice. Discuss any changes with your clinician.",
                font: .systemFont(ofSize: 9),
                color: .gray
            )
        }

        let fileName = "Trio_Report_\(summary.rangeLabel.replacingOccurrences(of: " ", with: "_")).pdf"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: url)
        try data.write(to: url)
        return url
    }

    private func drawChart(_ points: [(date: Date, avg: Double)], in rect: CGRect, context: CGContext) {
        // Axes
        context.setStrokeColor(UIColor.lightGray.cgColor)
        context.setLineWidth(0.5)
        context.stroke(rect)

        guard points.count > 1 else {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 11),
                .foregroundColor: UIColor.gray
            ]
            ("Not enough data to chart." as NSString).draw(
                at: CGPoint(x: rect.minX + 8, y: rect.midY - 6),
                withAttributes: attrs
            )
            return
        }

        let minY = 40.0
        let maxY = 300.0
        func yFor(_ value: Double) -> CGFloat {
            let clamped = max(minY, min(maxY, value))
            let frac = (clamped - minY) / (maxY - minY)
            return rect.maxY - CGFloat(frac) * rect.height
        }
        func xFor(_ index: Int) -> CGFloat {
            rect.minX + rect.width * CGFloat(index) / CGFloat(max(1, points.count - 1))
        }

        // Target band (70–180) shading.
        let bandTop = yFor(180)
        let bandBottom = yFor(70)
        context.setFillColor(UIColor.systemGreen.withAlphaComponent(0.10).cgColor)
        context.fill(CGRect(x: rect.minX, y: bandTop, width: rect.width, height: bandBottom - bandTop))

        // Line.
        context.setStrokeColor(UIColor.systemBlue.cgColor)
        context.setLineWidth(1.5)
        let path = UIBezierPath()
        for (index, point) in points.enumerated() {
            let p = CGPoint(x: xFor(index), y: yFor(point.avg))
            if index == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        context.addPath(path.cgPath)
        context.strokePath()

        // Y labels in the user's unit.
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 8),
            .foregroundColor: UIColor.gray
        ]
        for value in [70.0, 180.0, 300.0] {
            ("\(glucoseText(value))" as NSString).draw(
                at: CGPoint(x: rect.maxX + 4, y: yFor(value) - 5),
                withAttributes: labelAttrs
            )
        }
    }
}
