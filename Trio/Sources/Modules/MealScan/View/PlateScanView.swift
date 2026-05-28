import SwiftUI
import Swinject
import UIKit

extension MealScan {
    /// One-shot plate analysis: snap a meal photo, the AI estimates macros,
    /// you review/adjust, and the numbers drop straight into the bolus fields.
    /// For a back-and-forth conversation, use StandaloneChatView instead.
    struct PlateScanView: View {
        let resolver: Resolver

        @Environment(\.dismiss) var dismiss

        @State private var provider: MealScanProvider?
        @State private var phase: Phase = .camera
        @State private var capturedImage: UIImage?
        @State private var analysisText: String = ""
        @State private var totals: NutritionTotals?
        @State private var errorMessage: String?
        @State private var showError = false

        @State private var editableCarbs: Decimal = 0
        @State private var editableFat: Decimal = 0
        @State private var editableProtein: Decimal = 0

        /// Returns the (possibly edited) totals to apply to the bolus form.
        var onConfirm: ((NutritionTotals) -> Void)?

        enum Phase {
            case camera
            case analyzing
            case review
        }

        var body: some View {
            NavigationStack {
                Group {
                    switch phase {
                    case .camera:
                        CameraCaptureView(
                            onImageCaptured: { image in
                                capturedImage = image
                                phase = .analyzing
                                Task { await analyze(image) }
                            },
                            onCancel: { dismiss() }
                        )

                    case .analyzing:
                        VStack(spacing: 16) {
                            ProgressView().scaleEffect(1.5)
                            Text("Analyzing your plate...")
                                .font(.headline)
                            Text("Identifying foods and estimating carbs")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }

                    case .review:
                        reviewForm
                    }
                }
                .navigationTitle(navigationTitle)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    if phase != .camera {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { dismiss() }
                        }
                    }
                    if phase == .review {
                        ToolbarItem(placement: .primaryAction) {
                            Button("Retake") { phase = .camera }
                        }
                    }
                }
                .alert("Error", isPresented: $showError) {
                    Button("Try Again") { showError = false; phase = .camera }
                    Button("Cancel", role: .cancel) { showError = false; dismiss() }
                } message: {
                    Text(errorMessage ?? "Unable to analyze the photo.")
                }
            }
            .onAppear {
                if provider == nil {
                    provider = MealScanProvider(resolver: resolver)
                }
            }
        }

        private var navigationTitle: String {
            switch phase {
            case .camera: return "Scan Plate"
            case .analyzing: return "Analyzing..."
            case .review: return "Meal Estimate"
            }
        }

        @ViewBuilder
        private var reviewForm: some View {
            Form {
                if let image = capturedImage {
                    Section {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 180)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                }

                Section("Estimated Macros") {
                    macroRow("Carbs", value: $editableCarbs)
                    macroRow("Fat", value: $editableFat)
                    macroRow("Protein", value: $editableProtein)
                }

                if let totals, totals.superBolusRecommendation != .no {
                    Section {
                        superBolusBanner(totals)
                    }
                }

                if !analysisText.isEmpty {
                    Section("AI Notes") {
                        Text(analysisText)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    Button {
                        apply()
                    } label: {
                        Text("Use These Numbers")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                    .listRowBackground(editableCarbs == 0 && editableFat == 0 && editableProtein == 0
                        ? Color(.systemGray3) : Color.green)
                    .foregroundStyle(.white)
                    .disabled(editableCarbs == 0 && editableFat == 0 && editableProtein == 0)
                } footer: {
                    Text("Not quite right? Use the chat button on the bolus screen to discuss it with the AI.")
                }
            }
        }

        private func macroRow(_ label: String, value: Binding<Decimal>) -> some View {
            HStack {
                Text(label)
                Spacer()
                TextField("0", value: value, format: .number)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                Text("g").foregroundStyle(.secondary)
            }
        }

        @ViewBuilder
        private func superBolusBanner(_ totals: NutritionTotals) -> some View {
            HStack(spacing: 10) {
                Image(systemName: totals.superBolusRecommendation == .yes ? "bolt.fill" : "bolt.circle")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(totals.superBolusRecommendation == .yes ? "Super Bolus Recommended" : "Consider Super Bolus")
                        .font(.subheadline).fontWeight(.semibold)
                    if !totals.superBolusReason.isEmpty {
                        Text(totals.superBolusReason)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }

        @MainActor
        private func analyze(_ image: UIImage) async {
            guard let provider else {
                errorMessage = "Provider not ready"
                showError = true
                return
            }
            do {
                let stream = try await provider.startFreeFormChat(
                    initialMessage: "Analyze this plate of food and give your best single-shot nutrition estimate. State your portion assumptions briefly.",
                    image: image
                )
                var text = ""
                for await chunk in stream {
                    text += chunk
                }

                if let parsed = BaseClaudeNutritionService.parseTotals(from: text) {
                    totals = parsed
                    editableCarbs = parsed.carbs
                    editableFat = parsed.fat
                    editableProtein = parsed.protein
                }
                analysisText = Self.stripNutritionBlock(text)
                phase = .review
            } catch {
                errorMessage = error.localizedDescription
                showError = true
            }
        }

        private func apply() {
            // Keep speed / super-bolus signal from the AI, override macros with edits.
            var result = totals ?? .zero
            result.carbs = editableCarbs
            result.fat = editableFat
            result.protein = editableProtein
            onConfirm?(result)
            dismiss()
        }

        private static func stripNutritionBlock(_ text: String) -> String {
            if let range = text.range(of: "```nutrition") {
                return String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}
