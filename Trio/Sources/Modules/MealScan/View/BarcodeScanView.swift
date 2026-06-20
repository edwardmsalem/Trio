import AVFoundation
import CoreData
import SwiftUI
import Swinject
import UIKit

extension MealScan {
    /// Scan a UPC/EAN barcode, look the product up in OpenFoodFacts (free, no key),
    /// and prefill a preset. Faster and more exact than photographing a label.
    struct BarcodeScanView: View {
        let resolver: Resolver

        @Environment(\.dismiss) var dismiss
        @Environment(\.managedObjectContext) private var moc

        @State private var phase: Phase = .scanning
        @State private var scannedCode: String?
        @State private var errorMessage: String?
        @State private var showError = false

        @State private var dish: String = ""
        @State private var carbs: Decimal = 0
        @State private var fat: Decimal = 0
        @State private var protein: Decimal = 0
        @State private var servingNote: String = ""

        var onConfirm: ((NutritionTotals) -> Void)?

        enum Phase { case scanning, lookup, review }

        var body: some View {
            NavigationStack {
                Group {
                    switch phase {
                    case .scanning:
                        BarcodeCameraView(
                            onCode: { code in
                                guard scannedCode == nil else { return }
                                scannedCode = code
                                phase = .lookup
                                Task { await lookup(code) }
                            },
                            onCancel: { dismiss() }
                        )
                        .overlay(alignment: .bottom) {
                            Text("Point at a barcode")
                                .font(.subheadline)
                                .padding(10)
                                .background(.ultraThinMaterial, in: Capsule())
                                .padding(.bottom, 30)
                        }

                    case .lookup:
                        VStack(spacing: 16) {
                            ProgressView().scaleEffect(1.5)
                            Text("Looking up product...")
                                .font(.headline)
                        }

                    case .review:
                        reviewForm
                    }
                }
                .navigationTitle(navTitle)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    if phase != .scanning {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { dismiss() }
                        }
                    }
                }
                .alert("Not found", isPresented: $showError) {
                    Button("Scan Again") { showError = false
                        scannedCode = nil
                        phase = .scanning }
                    Button("Cancel", role: .cancel) { showError = false
                        dismiss() }
                } message: {
                    Text(errorMessage ?? "Couldn't find that product.")
                }
            }
        }

        private var navTitle: String {
            switch phase {
            case .scanning: return "Scan Barcode"
            case .lookup: return "Looking up..."
            case .review: return "Product"
            }
        }

        @ViewBuilder private var reviewForm: some View {
            Form {
                Section("Name") {
                    TextField("Product name", text: $dish)
                }
                Section("Per Serving") {
                    macroRow("Carbs", $carbs)
                    macroRow("Fat", $fat)
                    macroRow("Protein", $protein)
                }
                if !servingNote.isEmpty {
                    Section("Serving") { Text(servingNote).foregroundStyle(.secondary) }
                }
                Section {
                    Button {
                        if let totals = totalsFromForm() {
                            onConfirm?(totals)
                            dismiss()
                        }
                    } label: {
                        Text("Use These Numbers").frame(maxWidth: .infinity)
                    }
                    .listRowBackground(noMacros ? Color(.systemGray3) : Color.green)
                    .foregroundStyle(.white)
                    .disabled(noMacros)

                    Button {
                        savePreset()
                    } label: {
                        Label("Save as Preset", systemImage: "bookmark").frame(maxWidth: .infinity)
                    }
                    .disabled(dish.isEmpty || noMacros)
                }
            }
        }

        private var noMacros: Bool { carbs == 0 && fat == 0 && protein == 0 }

        private func macroRow(_ label: String, _ value: Binding<Decimal>) -> some View {
            HStack {
                Text(label)
                Spacer()
                TextField("0", value: value, format: .number)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                Text("g").foregroundStyle(.secondary)
            }
        }

        private func totalsFromForm() -> NutritionTotals? {
            guard !noMacros else { return nil }
            var t = NutritionTotals.zero
            t.carbs = carbs
            t.fat = fat
            t.protein = protein
            t.netCarbs = carbs
            t.name = dish.isEmpty ? nil : dish
            return t
        }

        private func savePreset() {
            let name = dish.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return }
            let preset = MealPresetStored(context: moc)
            preset.dish = String(name.prefix(25))
            preset.carbs = carbs as NSDecimalNumber
            preset.fat = fat as NSDecimalNumber
            preset.protein = protein as NSDecimalNumber
            if !servingNote.isEmpty { preset.customFoodNote = servingNote }
            try? moc.save()
            dismiss()
        }

        @MainActor private func lookup(_ code: String) async {
            do {
                let product = try await OpenFoodFacts.lookup(code)
                dish = product.name
                carbs = product.carbs
                fat = product.fat
                protein = product.protein
                servingNote = product.servingDescription
                phase = .review
            } catch {
                errorMessage = error.localizedDescription
                showError = true
            }
        }
    }
}

// MARK: - OpenFoodFacts lookup

enum OpenFoodFacts {
    struct Product {
        let name: String
        let carbs: Decimal
        let fat: Decimal
        let protein: Decimal
        let servingDescription: String
    }

    enum LookupError: LocalizedError {
        case notFound
        case noNutrition
        var errorDescription: String? {
            switch self {
            case .notFound: return "Product not in the OpenFoodFacts database. Try the label scanner instead."
            case .noNutrition: return "That product has no nutrition data on file. Try the label scanner."
            }
        }
    }

    static func lookup(_ code: String) async throws -> Product {
        let urlStr =
            "https://world.openfoodfacts.org/api/v2/product/\(code).json?fields=product_name,brands,nutriments,serving_size,serving_quantity"
        guard let url = URL(string: urlStr) else { throw LookupError.notFound }

        var request = URLRequest(url: url)
        request.setValue("Trio-MealScan/1.0", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20

        let (data, _) = try await URLSession.shared.data(for: request)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LookupError.notFound
        }
        let status = (root["status"] as? Int) ?? 0
        guard status == 1, let product = root["product"] as? [String: Any],
              let nutr = product["nutriments"] as? [String: Any]
        else { throw LookupError.notFound }

        // Values are per 100g; scale to one serving when serving_quantity is present.
        let servingQty = decimal(product["serving_quantity"]) // grams per serving
        let scale: Decimal = (servingQty > 0) ? servingQty / 100 : 1

        let carbs100 = decimal(nutr["carbohydrates_100g"])
        let fat100 = decimal(nutr["fat_100g"])
        let protein100 = decimal(nutr["proteins_100g"])
        if carbs100 == 0, fat100 == 0, protein100 == 0 { throw LookupError.noNutrition }

        let name = [product["brands"] as? String, product["product_name"] as? String]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        let serving = (product["serving_size"] as? String).map { "Per serving: \($0)" } ?? "Per 100g"

        return Product(
            name: name.isEmpty ? "Scanned product" : name,
            carbs: round1(carbs100 * scale),
            fat: round1(fat100 * scale),
            protein: round1(protein100 * scale),
            servingDescription: serving
        )
    }

    private static func decimal(_ any: Any?) -> Decimal {
        if let n = any as? NSNumber { return n.decimalValue }
        if let s = any as? String, let d = Decimal(string: s) { return d }
        return 0
    }

    private static func round1(_ d: Decimal) -> Decimal {
        var v = d
        var r = Decimal()
        NSDecimalRound(&r, &v, 1, .plain)
        return r
    }
}

// MARK: - Camera scanner

struct BarcodeCameraView: UIViewControllerRepresentable {
    let onCode: (String) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context _: Context) -> ScannerVC {
        let vc = ScannerVC()
        vc.onCode = onCode
        return vc
    }

    func updateUIViewController(_: ScannerVC, context _: Context) {}

    final class ScannerVC: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
        var onCode: ((String) -> Void)?
        private let session = AVCaptureSession()
        private var preview: AVCaptureVideoPreviewLayer?

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black
            configure()
        }

        private func configure() {
            guard let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input)
            else { return }
            session.addInput(input)

            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else { return }
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.ean13, .ean8, .upce, .code128]

            let layer = AVCaptureVideoPreviewLayer(session: session)
            layer.videoGravity = .resizeAspectFill
            layer.frame = view.layer.bounds
            view.layer.addSublayer(layer)
            preview = layer

            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.session.startRunning()
            }
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            preview?.frame = view.layer.bounds
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            if session.isRunning { session.stopRunning() }
        }

        func metadataOutput(
            _: AVCaptureMetadataOutput,
            didOutput metadataObjects: [AVMetadataObject],
            from _: AVCaptureConnection
        ) {
            guard let obj = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
                  let code = obj.stringValue else { return }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            session.stopRunning()
            onCode?(code)
        }
    }
}
