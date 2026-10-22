import Charts
import SwiftUI
import WidgetKit

// MARK: - Timeline

struct GlucoseWidgetEntry: TimelineEntry {
    let date: Date
    let data: GlucoseWidgetData?
}

struct GlucoseWidgetProvider: TimelineProvider {
    func placeholder(in _: Context) -> GlucoseWidgetEntry {
        GlucoseWidgetEntry(date: Date(), data: .placeholder)
    }

    func getSnapshot(in _: Context, completion: @escaping (GlucoseWidgetEntry) -> Void) {
        completion(GlucoseWidgetEntry(date: Date(), data: GlucoseWidgetData.load() ?? .placeholder))
    }

    func getTimeline(in _: Context, completion: @escaping (Timeline<GlucoseWidgetEntry>) -> Void) {
        let data = GlucoseWidgetData.load()
        let now = Date()
        var entries: [GlucoseWidgetEntry] = [GlucoseWidgetEntry(date: now, data: data)]

        guard let data else {
            completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(30 * 60))))
            return
        }

        // One entry just past each staleness threshold, measured from the READING
        // time, so the widget dims and marks itself stale on its own even when
        // iOS refuses further reloads. No reload budget is spent on these.
        let thresholds: [TimeInterval] = [
            GlucoseWidgetData.agingAfter,
            GlucoseWidgetData.staleAfter,
            GlucoseWidgetData.veryStaleAfter,
            60 * 60
        ]
        for offset in thresholds {
            let crossing = data.date.addingTimeInterval(offset + 1)
            if crossing > now { entries.append(GlucoseWidgetEntry(date: crossing, data: data)) }
        }

        // Safety net only: the app reloads us when a reading is worth it and saves
        // every reading to the App Group, so a self-scheduled refresh picks up any
        // reading the app held back to save budget. Spaced like the app's own
        // longest gap, and slower once stale (no new readings are arriving).
        let refresh: Date
        if data.age(at: now) < GlucoseWidgetData.staleAfter {
            refresh = max(data.date.addingTimeInterval(GlucoseWidgetReloadPolicy.maxInterval), now.addingTimeInterval(5 * 60))
        } else {
            refresh = now.addingTimeInterval(30 * 60)
        }
        completion(Timeline(entries: entries, policy: .after(refresh)))
    }
}

// MARK: - Shared pieces

private struct TrendGlucose: View {
    let data: GlucoseWidgetData
    let now: Date
    var glucoseFont: Font = .system(size: 22, weight: .bold, design: .rounded)

    var body: some View {
        HStack(spacing: 2) {
            Text(data.glucose)
                .font(glucoseFont)
                .foregroundStyle(.primary)
                .staleStyled(data, at: now)
            Text(data.trend.isEmpty ? "→" : data.trend)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.secondary)
                .staleStyled(data, at: now)
        }
    }
}

/// Dims an old reading and strikes it through once it is very old, so a stale
/// value never reads as current (works in the monochrome lock-screen style too).
private struct StaleStyle: ViewModifier {
    let freshness: GlucoseWidgetData.Freshness

    func body(content: Content) -> some View {
        switch freshness {
        case .aging,
             .fresh:
            content
        case .stale:
            content.opacity(0.45)
        case .veryStale:
            content.opacity(0.3).strikethrough(true)
        }
    }
}

private extension View {
    func staleStyled(_ data: GlucoseWidgetData, at now: Date) -> some View {
        modifier(StaleStyle(freshness: data.freshness(at: now)))
    }
}

/// Warning symbol shown next to the reading time once the reading is stale.
/// A symbol, not only a color, so it reads on the tinted lock screen.
private struct StaleSymbol: View {
    let data: GlucoseWidgetData
    let now: Date
    var font: Font = .caption2

    var body: some View {
        switch data.freshness(at: now) {
        case .stale:
            Image(systemName: "exclamationmark.triangle.fill").font(font).foregroundStyle(.orange)
        case .veryStale:
            Image(systemName: "exclamationmark.triangle.fill").font(font).foregroundStyle(.red)
        case .aging,
             .fresh:
            EmptyView()
        }
    }
}

/// "@ 10:45" (the reading's clock time). Once stale it adds a live-updating age,
/// "@ 10:45 · 2 hr ago", which the system ticks without a reload.
extension Text {
    /// Live-updating age of a reading in whole minutes or hours, for example
    /// "17 min ago" or "2 hr ago". The system ticks it without a widget reload.
    /// `style: .relative` adds seconds ("16 min, 58 sec"), which ran past the
    /// width of the widget's left column and got cut off.
    static func readingAge(since date: Date) -> Text {
        Text(.currentDate, format: .reference(to: date, allowedFields: [.hour, .minute], maxFieldCount: 1))
    }
}

private struct ReadingTimeLabel: View {
    let data: GlucoseWidgetData
    let now: Date
    var showsAgeWhenStale = true

    var body: some View {
        let isStale = data.age(at: now) > GlucoseWidgetData.staleAfter
        HStack(spacing: 3) {
            StaleSymbol(data: data, now: now)
            if isStale, showsAgeWhenStale {
                Text("@ \(data.timeString) · \(Text.readingAge(since: data.date))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            } else {
                Text("@ \(data.timeString)").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

private struct NoDataView: View {
    var body: some View {
        VStack(spacing: 2) {
            Image(systemName: "drop.fill").foregroundStyle(.secondary)
            Text("--").font(.headline).foregroundStyle(.secondary)
        }
    }
}

/// Deep links into the app. "Advisor" opens the AI Meal Advisor chat (advice
/// only — it never doses); "Bolus" opens Trio's treatment-entry screen to log
/// carbs and dose. Dosing always requires in-app confirmation.
private enum WidgetShortcut {
    static let advisor = URL(string: "Trio://chat")!
    static let bolus = URL(string: "Trio://bolus")!
}

/// Compact shortcut buttons. `compact` uses icon-only pills for the small widget.
private struct ShortcutButtons: View {
    var compact: Bool = false

    var body: some View {
        HStack(spacing: 6) {
            Link(destination: WidgetShortcut.advisor) {
                label(systemImage: "bubble.left.and.bubble.right.fill", text: "Advisor", tint: .purple)
            }
            Link(destination: WidgetShortcut.bolus) {
                label(systemImage: "syringe", text: "Bolus", tint: .blue)
            }
        }
    }

    @ViewBuilder private func label(systemImage: String, text: String, tint: Color) -> some View {
        if compact {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else {
            Label(text, systemImage: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
    }
}

// MARK: - Lock-screen views

private struct AccessoryCircularGlucose: View {
    let data: GlucoseWidgetData?
    let now: Date
    var body: some View {
        if let data {
            ZStack {
                AccessoryWidgetBackground()
                VStack(spacing: 0) {
                    Text(data.glucose).font(.system(size: 18, weight: .bold, design: .rounded))
                        .staleStyled(data, at: now)
                    if data.age(at: now) > GlucoseWidgetData.staleAfter {
                        // No room for a time here: the symbol replaces the arrow.
                        Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10))
                    } else {
                        Text(data.trend.isEmpty ? "→" : data.trend).font(.system(size: 11))
                    }
                }
            }
        } else {
            ZStack { AccessoryWidgetBackground()
                Text("--").font(.headline) }
        }
    }
}

private struct AccessoryInlineGlucose: View {
    let data: GlucoseWidgetData?
    let now: Date
    var body: some View {
        if let data {
            if data.age(at: now) > GlucoseWidgetData.staleAfter {
                // Inline is one line of plain text: say it is old, with the time.
                Label("\(data.glucose) old @ \(data.timeString)", systemImage: "exclamationmark.triangle.fill")
            } else {
                Text("\(data.glucose) \(data.trend.isEmpty ? "→" : data.trend)  \(data.delta)  @ \(data.timeString)")
            }
        } else {
            Text("Glucose --")
        }
    }
}

private struct AccessoryRectangularGlucose: View {
    let data: GlucoseWidgetData?
    let now: Date
    var body: some View {
        if let data {
            let isStale = data.age(at: now) > GlucoseWidgetData.staleAfter
            HStack(alignment: .center, spacing: 8) {
                Text(data.glucose).font(.system(size: 26, weight: .bold, design: .rounded))
                    .staleStyled(data, at: now)
                VStack(alignment: .leading, spacing: 1) {
                    Text(data.trend.isEmpty ? "→" : data.trend).font(.system(size: 14, weight: .semibold))
                        .staleStyled(data, at: now)
                    if isStale {
                        Text.readingAge(since: data.date)
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
                    } else {
                        Text(data.delta).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                ReadingTimeLabel(data: data, now: now, showsAgeWhenStale: false)
            }
        } else {
            Text("Glucose unavailable").font(.caption)
        }
    }
}

// MARK: - Home-screen views

private struct SmallGlucose: View {
    let data: GlucoseWidgetData?
    let now: Date
    var body: some View {
        ZStack {
            if let data {
                VStack(spacing: 5) {
                    HStack(spacing: 4) {
                        Circle().fill(data.stalenessColor(at: now)).frame(width: 8, height: 8)
                        ReadingTimeLabel(data: data, now: now, showsAgeWhenStale: false)
                    }
                    TrendGlucose(data: data, now: now, glucoseFont: .system(size: 34, weight: .bold, design: .rounded))
                    if data.age(at: now) > GlucoseWidgetData.staleAfter {
                        Text.readingAge(since: data.date)
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
                    } else {
                        Text(data.delta).font(.caption2).foregroundStyle(.secondary)
                    }
                    ShortcutButtons(compact: true)
                }
                .padding(12)
            } else {
                VStack(spacing: 8) {
                    NoDataView()
                    ShortcutButtons(compact: true)
                }
                .padding(12)
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

private struct MediumGlucose: View {
    let data: GlucoseWidgetData?
    let now: Date
    var body: some View {
        ZStack {
            if let data {
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 4) {
                            Circle().fill(data.stalenessColor(at: now)).frame(width: 8, height: 8)
                            ReadingTimeLabel(data: data, now: now, showsAgeWhenStale: false)
                        }
                        TrendGlucose(data: data, now: now, glucoseFont: .system(size: 44, weight: .bold, design: .rounded))
                        if data.age(at: now) > GlucoseWidgetData.staleAfter {
                            Text.readingAge(since: data.date)
                                .font(.subheadline).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
                        } else {
                            Text("Δ \(data.delta)").font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 6) {
                        HStack(spacing: 10) {
                            if let iob = data.iob, !iob.isEmpty, iob != "--" {
                                Label("\(iob) U", systemImage: "drop").font(.caption2).foregroundStyle(.secondary)
                            }
                            if let cob = data.cob, !cob.isEmpty, cob != "--" {
                                Label("\(cob) g", systemImage: "fork.knife").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        ShortcutButtons()
                            .frame(width: 150)
                    }
                }
                .padding()
            } else {
                VStack(spacing: 10) {
                    NoDataView()
                    ShortcutButtons().frame(width: 200)
                }
                .padding()
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

/// The biggest home-screen size: header (timestamp + IOB/COB), the big reading,
/// a glucose trend chart with the target band shaded, and the shortcut buttons.
private struct LargeGlucose: View {
    let data: GlucoseWidgetData?
    let now: Date

    var body: some View {
        ZStack {
            if let data {
                VStack(alignment: .leading, spacing: 10) {
                    header(data)
                    readingRow(data)
                    chart(data)
                        .frame(maxHeight: .infinity)
                    ShortcutButtons()
                }
                .padding()
            } else {
                VStack(spacing: 12) {
                    NoDataView()
                    ShortcutButtons().frame(width: 220)
                }
                .padding()
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }

    private func header(_ data: GlucoseWidgetData) -> some View {
        HStack {
            HStack(spacing: 5) {
                Circle().fill(data.stalenessColor(at: now)).frame(width: 8, height: 8)
                ReadingTimeLabel(data: data, now: now)
            }
            Spacer()
            HStack(spacing: 12) {
                if let iob = data.iob, !iob.isEmpty, iob != "--" {
                    Label("\(iob) U", systemImage: "drop").font(.caption2).foregroundStyle(.secondary)
                }
                if let cob = data.cob, !cob.isEmpty, cob != "--" {
                    Label("\(cob) g", systemImage: "fork.knife").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func readingRow(_ data: GlucoseWidgetData) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(data.glucose)
                .font(.system(size: 52, weight: .bold, design: .rounded))
                .staleStyled(data, at: now)
            Text(data.trend.isEmpty ? "→" : data.trend)
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(.secondary)
                .staleStyled(data, at: now)
            Spacer()
            Text("Δ \(data.delta)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func chart(_ data: GlucoseWidgetData) -> some View {
        if let history = data.history, history.count >= 2 {
            let values = history.map(\.glucose)
            let lowLine = data.low
            let highLine = data.high
            let minY = min(values.min() ?? 0, lowLine ?? .greatestFiniteMagnitude) * 0.9
            let maxY = max(values.max() ?? 0, highLine ?? 0) * 1.1

            Chart {
                if let lowLine, let highLine {
                    RectangleMark(
                        yStart: .value("Low", lowLine),
                        yEnd: .value("High", highLine)
                    )
                    .foregroundStyle(.green.opacity(0.12))
                }
                ForEach(history) { point in
                    LineMark(
                        x: .value("Time", point.date),
                        y: .value("Glucose", point.glucose)
                    )
                    .interpolationMethod(.catmullRom)
                    .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .foregroundStyle(.cyan)
                }
                if let last = history.last {
                    PointMark(
                        x: .value("Time", last.date),
                        y: .value("Glucose", last.glucose)
                    )
                    .symbolSize(60)
                    .foregroundStyle(data.isInRange ? Color.green : Color.orange)
                }
            }
            .chartYScale(domain: minY ... maxY)
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) {
                    AxisGridLine().foregroundStyle(.secondary.opacity(0.25))
                    AxisValueLabel().font(.caption2).foregroundStyle(.secondary)
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 3)) {
                    AxisValueLabel(format: .dateTime.hour().minute())
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        } else {
            // Not enough samples yet for a chart — keep the slot so layout is stable.
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.fill.quaternary)
                .overlay(
                    Text("Building trend…")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                )
        }
    }
}

// MARK: - Widget configurations

struct TrioGlucoseLockWidget: Widget {
    let kind = "TrioGlucoseLockWidget"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: GlucoseWidgetProvider()) { entry in
            GlucoseLockEntryView(entry: entry)
        }
        .configurationDisplayName("Glucose (Lock Screen)")
        .description("Live glucose with trend under your clock.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

private struct GlucoseLockEntryView: View {
    @Environment(\.widgetFamily) var family
    let entry: GlucoseWidgetEntry
    var body: some View {
        // Lock-screen accessory widgets take a single tap target; send it to the
        // carb/bolus entry screen (never doses directly).
        Group {
            switch family {
            case .accessoryCircular: AccessoryCircularGlucose(data: entry.data, now: entry.date)
            case .accessoryInline: AccessoryInlineGlucose(data: entry.data, now: entry.date)
            default: AccessoryRectangularGlucose(data: entry.data, now: entry.date)
            }
        }
        .widgetURL(WidgetShortcut.bolus)
    }
}

struct TrioGlucoseHomeWidget: Widget {
    let kind = "TrioGlucoseHomeWidget"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: GlucoseWidgetProvider()) { entry in
            GlucoseHomeEntryView(entry: entry)
        }
        .configurationDisplayName("Glucose")
        .description("Current glucose, trend, and delta on your Home Screen.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

private struct GlucoseHomeEntryView: View {
    @Environment(\.widgetFamily) var family
    let entry: GlucoseWidgetEntry
    var body: some View {
        switch family {
        case .systemLarge: LargeGlucose(data: entry.data, now: entry.date)
        case .systemMedium: MediumGlucose(data: entry.data, now: entry.date)
        default: SmallGlucose(data: entry.data, now: entry.date)
        }
    }
}
