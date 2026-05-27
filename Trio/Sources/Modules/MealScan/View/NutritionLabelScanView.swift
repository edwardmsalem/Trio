import CoreData
import SwiftUI
import Swinject
import UIKit

extension MealScan {
    struct NutritionLabelScanView: View {
        let resolver: Resolver

        @Environment(\.dismiss) var dismiss
        @Environment(\.managedObjectContext) var moc

        @State private var provider: MealScanProvider?
        @State private var phase: Phase = .camera
        @State private var capturedImage: UIImage?
        @State private var errorMessage: String?
        @State private var showError = false

        @State private var editableDish: String = ""
        @State private var editableCarbs: Decimal = 0
        @State private var editableFat: Decimal = 0
        @State private var editableProtein: Decimal = 0
        @State private var editableNote: String = ""

        var onSaved: ((MealPresetStored) -> Void)?

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
                                Task { await parseLabel(image) }
                            },
                            onCancel: { dismiss() }
                        )

                    case .analyzing:
                        VStack(spacing: 16) {
                            ProgressView().scaleEffect(1.5)
                            Text("Reading nutrition label...")
                                .font(.headline)
                            Text("Extracting per-serving values")
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
                }
                .alert("Error", isPresented: $showError) {
                    Button("Try Again") {
                        showError = false
                        phase = .camera
                    }
                    Button("Cancel", role: .cancel) {
                        showError = false
                        dismiss()
                    }
                } message: {
                    Text(errorMessage ?? "Unable to read the label.")
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
            case .camera: return "Scan Nutrition Label"
            case .analyzing: return "Reading..."
            case .review: return "New Preset"
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
                            .frame(maxHeight: 160)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                }

                Section("Preset Name") {
                    TextField("e.g. Chobani Greek 0%", text: $editableDish)
                }

                Section("Per Serving") {
                    HStack {
                        Text("Carbs")
                        Spacer()
                        TextField("0", value: $editableCarbs, format: .number)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                        Text("g").foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Fat")
                        Spacer()
                        TextField("0", value: $editableFat, format: .number)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                        Text("g").foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Protein")
                        Spacer()
                        TextField("0", value: $editableProtein, format: .number)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                        Text("g").foregroundStyle(.secondary)
                    }
                }

                Section("Serving Size") {
                    TextField("1 bar (40g)", text: $editableNote, axis: .vertical)
                        .lineLimit(1 ... 3)
                }

                Section {
                    Button {
                        savePreset()
                    } label: {
                        Text("Save Preset")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(editableDish.isEmpty || editableCarbs == 0)
                    .listRowBackground(
                        (editableDish.isEmpty || editableCarbs == 0) ? Color(.systemGray3) : Color.blue
                    )
                    .foregroundStyle(.white)
                }
            }
        }

        @MainActor
        private func parseLabel(_ image: UIImage) async {
            guard let provider else {
                errorMessage = "Provider not ready"
                showError = true
                return
            }
            do {
                let label = try await provider.parseNutritionLabel(image: image)
                editableDish = label.dish
                editableCarbs = label.carbs
                editableFat = label.fat
                editableProtein = label.protein
                editableNote = label.servingDescription
                phase = .review
            } catch {
                errorMessage = error.localizedDescription
                showError = true
            }
        }

        private func savePreset() {
            let preset = MealPresetStored(context: moc)
            preset.dish = String(editableDish.prefix(25))
            preset.carbs = editableCarbs as NSDecimalNumber
            preset.fat = editableFat as NSDecimalNumber
            preset.protein = editableProtein as NSDecimalNumber
            if !editableNote.isEmpty {
                preset.customFoodNote = editableNote
            }

            do {
                try moc.save()
                onSaved?(preset)
                dismiss()
            } catch {
                errorMessage = "Couldn't save: \(error.localizedDescription)"
                showError = true
            }
        }
    }
}
