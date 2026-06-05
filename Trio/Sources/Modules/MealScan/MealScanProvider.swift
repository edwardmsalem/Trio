import CoreData
import Foundation
import Swinject
import UIKit

extension MealScan {
    final class MealScanProvider: BaseProvider {
        @Injected() var fatSecretService: FatSecretService!
        @Injected() var claudeService: ClaudeNutritionService!

        func recognizeImage(_ image: UIImage, eatenFoodIds: [String]) async throws -> [DetectedFood] {
            try await fatSecretService.recognizeImage(image, eatenFoodIds: eatenFoodIds)
        }

        func startChatSession(
            image: UIImage,
            detectedFoods: [DetectedFood],
            customFoodNotes: [(dish: String, note: String)]
        ) async throws -> AsyncStream<String> {
            try await claudeService.startSession(image: image, detectedFoods: detectedFoods, customFoodNotes: customFoodNotes)
        }

        func sendChatMessage(_ text: String) async throws -> AsyncStream<String> {
            try await claudeService.sendMessage(text)
        }

        func resetChat() {
            claudeService.resetSession()
        }

        /// Codex thread id, surfaced so MealChatSession can persist/restore it.
        var chatThreadId: String? {
            get { claudeService.activeThreadId }
            set { claudeService.activeThreadId = newValue }
        }

        func parseNutritionLabel(image: UIImage) async throws -> NutritionLabelData {
            try await claudeService.parseNutritionLabel(image: image)
        }

        func startFreeFormChat(initialMessage: String, image: UIImage?, contextBlock: String? = nil) async throws -> AsyncStream<String> {
            try await claudeService.startFreeFormChat(initialMessage: initialMessage, image: image, contextBlock: contextBlock)
        }

        func savePreset(from label: NutritionLabelData) {
            let context = CoreDataStack.shared.persistentContainer.viewContext
            let preset = MealPresetStored(context: context)
            preset.dish = label.dish
            preset.carbs = label.carbs as NSDecimalNumber
            preset.fat = label.fat as NSDecimalNumber
            preset.protein = label.protein as NSDecimalNumber
            if !label.servingDescription.isEmpty {
                preset.customFoodNote = "Per serving: \(label.servingDescription)"
            }
            try? context.save()
        }

        // MARK: - Eaten Foods Storage

        func fetchStoredFoodIds() -> [String] {
            let context = CoreDataStack.shared.persistentContainer.viewContext
            let request = MealPresetStored.fetchRequest()
            let presets = (try? context.fetch(request)) ?? []
            return presets.compactMap { $0.fatSecretFoodId }
        }

        func fetchCustomFoodNotes() -> [(dish: String, note: String)] {
            let context = CoreDataStack.shared.persistentContainer.viewContext
            let request = MealPresetStored.fetchRequest()
            let presets = (try? context.fetch(request)) ?? []
            return presets.compactMap { preset in
                guard let dish = preset.dish, let note = preset.customFoodNote, !note.isEmpty else { return nil }
                return (dish: dish, note: note)
            }
        }

        func storeFoodIds(from foods: [DetectedFood]) {
            let context = CoreDataStack.shared.persistentContainer.viewContext
            for food in foods where !food.isRemoved {
                guard let foodId = food.foodId else { continue }
                let foodIdString = String(foodId)

                let request = MealPresetStored.fetchRequest()
                request.predicate = NSPredicate(format: "fatSecretFoodId == %@", foodIdString)
                let existing = (try? context.fetch(request)) ?? []

                if existing.isEmpty {
                    let preset = MealPresetStored(context: context)
                    preset.dish = food.name
                    preset.fatSecretFoodId = foodIdString
                    preset.carbs = food.carbs as NSDecimalNumber
                    preset.fat = food.fat as NSDecimalNumber
                    preset.protein = food.protein as NSDecimalNumber
                }
            }
            try? context.save()
        }
    }
}
