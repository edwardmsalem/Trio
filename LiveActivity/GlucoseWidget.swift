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
        // A few staggered entries so the staleness color updates between pushes.
        var entries: [GlucoseWidgetEntry] = [GlucoseWidgetEntry(date: now, data: data)]
        for minutes in [5, 10, 15] {
            entries.append(GlucoseWidgetEntry(date: now.addingTimeInterval(Double(minutes) * 60), data: data))
        }
        completion(Timeline(entries: entries, policy: .atEnd))
    }
}

// MARK: - Shared pieces

private struct TrendGlucose: View {
    let data: GlucoseWidgetData
    var glucoseFont: Font = .system(size: 22, weight: .bold, design: .rounded)

    var body: some View {
        HStack(spacing: 2) {
            Text(data.glucose)
                .font(glucoseFont)
                .foregroundStyle(.primary)
            Text(data.trend.isEmpty ? "→" : data.trend)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.secondary)
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

/// Deep links into the app. "Meal" opens the AI meal scanner; "Bolus" opens the
/// carb/bolus entry screen. They never dose from the widget — dosing always
/// requires in-app confirmation.
private enum WidgetShortcut {
    static let meal = URL(string: "Trio://mealScan")!
    static let bolus = URL(string: "Trio://treatments")!
}

/// Compact shortcut buttons. `compact` uses icon-only pills for the small widget.
private struct ShortcutButtons: View {
    var compact: Bool = false

    var body: some View {
        HStack(spacing: 6) {
            Link(destination: WidgetShortcut.meal) {
                label(systemImage: "fork.knife", text: "Meal", tint: .green)
            }
            Link(destination: WidgetShortcut.bolus) {
                label(systemImage: "syringe", text: "Bolus", tint: .blue)
            }
        }
    }

    @ViewBuilder
    private func label(systemImage: String, text: String, tint: Color) -> some View {
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
    var body: some View {
        if let data {
            ZStack {
                AccessoryWidgetBackground()
                VStack(spacing: 0) {
                    Text(data.glucose).font(.system(size: 18, weight: .bold, design: .rounded))
                    Text(data.trend.isEmpty ? "→" : data.trend).font(.system(size: 11))
                }
            }
        } else {
            ZStack { AccessoryWidgetBackground(); Text("--").font(.headline) }
        }
    }
}

private struct AccessoryInlineGlucose: View {
    let data: GlucoseWidgetData?
    var body: some View {
        if let data {
            Text("\(data.glucose) \(data.trend.isEmpty ? "→" : data.trend)  \(data.delta)")
        } else {
            Text("Glucose --")
        }
    }
}

private struct AccessoryRectangularGlucose: View {
    let data: GlucoseWidgetData?
    var body: some View {
        if let data {
            HStack(alignment: .center, spacing: 8) {
                Text(data.glucose).font(.system(size: 26, weight: .bold, design: .rounded))
                VStack(alignment: .leading, spacing: 1) {
                    Text(data.trend.isEmpty ? "→" : data.trend).font(.system(size: 14, weight: .semibold))
                    Text(data.delta).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Text("@ \(data.timeString)").font(.caption2).foregroundStyle(.secondary)
            }
        } else {
            Text("Glucose unavailable").font(.caption)
        }
    }
}

// MARK: - Home-screen views

private struct SmallGlucose: View {
    let data: GlucoseWidgetData?
    var body: some View {
        ZStack {
            if let data {
                VStack(spacing: 5) {
                    HStack(spacing: 4) {
                        Circle().fill(data.stalenessColor).frame(width: 8, height: 8)
                        Text("@ \(data.timeString)").font(.caption2).foregroundStyle(.secondary)
                    }
                    TrendGlucose(data: data, glucoseFont: .system(size: 34, weight: .bold, design: .rounded))
                    Text(data.delta).font(.caption2).foregroundStyle(.secondary)
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
    var body: some View {
        ZStack {
            if let data {
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 4) {
                            Circle().fill(data.stalenessColor).frame(width: 8, height: 8)
                            Text("@ \(data.timeString)").font(.caption2).foregroundStyle(.secondary)
                        }
                        TrendGlucose(data: data, glucoseFont: .system(size: 44, weight: .bold, design: .rounded))
                        Text("Δ \(data.delta)").font(.subheadline).foregroundStyle(.secondary)
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
            case .accessoryCircular: AccessoryCircularGlucose(data: entry.data)
            case .accessoryInline: AccessoryInlineGlucose(data: entry.data)
            default: AccessoryRectangularGlucose(data: entry.data)
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
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

private struct GlucoseHomeEntryView: View {
    @Environment(\.widgetFamily) var family
    let entry: GlucoseWidgetEntry
    var body: some View {
        switch family {
        case .systemMedium: MediumGlucose(data: entry.data)
        default: SmallGlucose(data: entry.data)
        }
    }
}
