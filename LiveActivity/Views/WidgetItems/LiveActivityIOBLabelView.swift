import Foundation
import SwiftUI
import WidgetKit

struct LiveActivityIOBLabelView: View {
    var context: ActivityViewContext<LiveActivityAttributes>
    var additionalState: LiveActivityAttributes.ContentAdditionalState

    private var bolusFormatter: NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 1
        return formatter
    }

    var body: some View {
        VStack(spacing: 2) {
            HStack {
                Text(bolusFormatter.string(from: additionalState.iob as NSNumber) ?? "--")
                    .fontWeight(.bold)
                    .font(.title3)
                    .foregroundStyle(context.isStale ? .secondary : .primary)
                    .strikethrough(context.isStale, pattern: .solid, color: .red.opacity(0.6))

                Text(String(localized: "U", comment: "Insulin unit"))
                    .font(.headline).fontWeight(.bold)
                    .foregroundStyle(context.isStale ? .secondary : .primary)
                    .strikethrough(context.isStale, pattern: .solid, color: .red.opacity(0.6))
            }
            Text("IOB")
                .font(.subheadline)
                .foregroundStyle(.primary)
        }
    }
}

struct LiveActivityEventualBGLabelView: View {
    var context: ActivityViewContext<LiveActivityAttributes>
    var additionalState: LiveActivityAttributes.ContentAdditionalState

    var body: some View {
        VStack(spacing: 2) {
            HStack {
                Image(systemName: "arrow.forward")
                    .font(.headline).fontWeight(.bold)
                    .foregroundStyle(context.isStale ? .secondary : .primary)

                Text(additionalState.eventualBG.isEmpty ? "--" : additionalState.eventualBG)
                    .fontWeight(.bold)
                    .font(.title3)
                    .foregroundStyle(context.isStale ? .secondary : .primary)
                    .strikethrough(context.isStale, pattern: .solid, color: .red.opacity(0.6))
            }
            Text("Eventual")
                .font(.subheadline)
                .foregroundStyle(.primary)
        }
    }
}
