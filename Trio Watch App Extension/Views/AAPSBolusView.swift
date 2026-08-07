import SwiftUI
import WatchKit

/// Bolus from the wrist with the phone out of reach.
///
/// The flow is deliberately two steps. The dialled amount is only a *request*; AAPS
/// answers with the amount it is actually willing to give after applying the bolus
/// limits, and that answered figure is what gets confirmed. When the two differ the
/// screen says so in words rather than quietly showing a smaller number, because a dose
/// that silently shrinks is a dose the user will redose on top of.
///
/// Confirmation is a crown rotation rather than a tap, matching the rest of the app —
/// insulin should never be one stray touch away.
struct AAPSBolusView: View {
    @Binding var navigationPath: NavigationPath

    /// The most this screen will ever offer to request. AAPS applies the real limit; this
    /// only keeps the dial in a sane range so the crown is usable.
    var dialLimit: Double = 10.0
    var increment: Double = 0.05

    @State private var stage: Stage = .compose
    @State private var insulin: Double = 0
    @State private var carbs: Double = 0
    @State private var commandId: String?
    @State private var quote: AAPSRemote.Quote?
    @State private var confirmationProgress: Double = 0
    @State private var failure: String?

    @FocusState private var crownFocus: Field?

    private enum Field { case insulin, carbs, confirm }

    private enum Stage { case compose, waiting, review, sending, done }

    private let background = LinearGradient(
        gradient: Gradient(colors: [Color.bgDarkBlue, Color.bgDarkerDarkBlue]),
        startPoint: .top,
        endPoint: .bottom
    )

    var body: some View {
        ZStack {
            background.ignoresSafeArea()
            switch stage {
            case .compose: compose
            case .waiting: waiting
            case .review: review
            case .sending: sending
            case .done: done
            }
        }
        .navigationTitle("Bolus")
    }

    // MARK: - Compose

    private var compose: some View {
        VStack(spacing: 8) {
            dial(
                label: String(localized: "Insulin"),
                value: String(format: "%.2f U", floor(insulin / increment) * increment),
                binding: $insulin,
                limit: dialLimit,
                step: increment,
                field: .insulin
            )

            dial(
                label: String(localized: "Carbs"),
                value: "\(Int(carbs)) g",
                binding: $carbs,
                limit: 200,
                step: 1,
                field: .carbs
            )

            Button(action: send) {
                Text("Send")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(insulin <= 0 && carbs <= 0)

            if let failure {
                Text(failure)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 6)
        .onAppear { crownFocus = .insulin }
    }

    private func dial(
        label: String,
        value: String,
        binding: Binding<Double>,
        limit: Double,
        step: Double,
        field: Field
    ) -> some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .fontWeight(.bold)
                .font(.system(.title3, design: .rounded))
                .foregroundStyle(crownFocus == field ? Color.accentColor : .primary)
                .focusable(true)
                .focused($crownFocus, equals: field)
                .digitalCrownRotation(
                    binding,
                    from: 0,
                    through: limit,
                    by: step,
                    sensitivity: .medium,
                    isContinuous: false,
                    isHapticFeedbackEnabled: true
                )
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
        .background(Color.white.opacity(crownFocus == field ? 0.12 : 0.05))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture { crownFocus = field }
    }

    // MARK: - Waiting

    private var waiting: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text("Asking your phone…")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Review

    @ViewBuilder private var review: some View {
        if let quote {
            VStack(spacing: 6) {
                if let refused = quote.refused {
                    Text("Not sent")
                        .font(.headline)
                        .foregroundStyle(.red)
                    Text(refused)
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                    Button("Back") { reset() }
                        .buttonStyle(.bordered)
                } else {
                    // The figure that will actually be delivered, made the biggest thing
                    // on screen. When it differs from what was asked, that is stated
                    // rather than left for the user to notice.
                    Text(String(format: "%.2f U", quote.insulin))
                        .fontWeight(.bold)
                        .font(.system(.title, design: .rounded))
                    if quote.carbs > 0 {
                        Text("with \(quote.carbs) g carbs")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if quote.wasTrimmed {
                        Text(String(format: "Asked %.2f U — limited by your settings", quote.requested))
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .multilineTextAlignment(.center)
                    }

                    Text("Turn the crown to confirm")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    // A deliberately chunky bar rather than the hairline default: this is
                    // the control being operated, and it has to be readable at a glance
                    // with a wrist half-turned away.
                    ConfirmBar(progress: confirmationProgress)

                    Button("Cancel") { cancel() }
                        .buttonStyle(.bordered)
                }
            }
            .padding(.horizontal, 8)
            .focusable(true)
            .focused($crownFocus, equals: .confirm)
            .digitalCrownRotation(
                $confirmationProgress,
                from: 0,
                through: 1.0,
                by: 0.05,
                sensitivity: .medium,
                isContinuous: false,
                isHapticFeedbackEnabled: true
            )
            .onAppear { crownFocus = .confirm }
            .onChange(of: confirmationProgress) { _, value in
                if value >= 1.0 { confirm() }
            }
        }
    }

    private var sending: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text("Delivering…").font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var done: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.largeTitle)
                .foregroundStyle(Color.loopGreen)
            Text("Sent to pump").font(.footnote).foregroundStyle(.secondary)
            Button("Done") { navigationPath = NavigationPath() }
                .buttonStyle(.bordered)
        }
    }

    /// The crown-turn confirmation indicator.
    private struct ConfirmBar: View {
        let progress: Double

        var body: some View {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.15))
                    Capsule()
                        .fill(progress >= 1.0 ? Color.loopGreen : Color.accentColor)
                        .frame(width: max(0, min(1, progress)) * geo.size.width)
                }
            }
            .frame(height: 14)
            .animation(.easeOut(duration: 0.12), value: progress)
        }
    }

    // MARK: - Actions

    private func send() {
        failure = nil
        stage = .waiting
        let requested = floor(insulin / increment) * increment
        Task {
            do {
                let id = try await AAPSRemote.shared.requestBolus(insulin: requested, carbs: Int(carbs))
                commandId = id
                let q = try await AAPSRemote.shared.awaitQuote(for: id)
                await MainActor.run {
                    quote = q
                    confirmationProgress = 0
                    stage = .review
                }
            } catch {
                await MainActor.run {
                    failure = error.localizedDescription
                    stage = .compose
                }
            }
        }
    }

    private func confirm() {
        guard let commandId else { return }
        WKInterfaceDevice.current().play(.success)
        stage = .sending
        Task {
            do {
                try await AAPSRemote.shared.confirmBolus(confirming: commandId)
                _ = await AAPSRemote.shared.awaitOutcome(for: commandId)
                await MainActor.run { stage = .done }
            } catch {
                await MainActor.run {
                    failure = error.localizedDescription
                    stage = .compose
                }
            }
        }
    }

    private func cancel() {
        Task { await AAPSRemote.shared.cancel() }
        reset()
    }

    private func reset() {
        quote = nil
        commandId = nil
        confirmationProgress = 0
        stage = .compose
        crownFocus = .insulin
    }
}
