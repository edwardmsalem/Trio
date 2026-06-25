import Combine
import Foundation
import Observation
import SwiftUI
import Swinject
import UIKit

extension MealScan {
    @Observable final class StateModel: BaseStateModel<MealScanProvider> {
        var capturedImage: UIImage?
        var phase: MealScanPhase = .camera
        var detectedFoods: [DetectedFood] = []
        var chatMessages: [ChatMessage] = []
        var currentStreamingText: String = ""
        var userInput: String = ""
        var isStreaming: Bool = false
        var errorMessage: String?
        var showError: Bool = false

        var runningTotals: NutritionTotals = .zero

        var onConfirm: ((NutritionTotals) -> Void)?

        // MARK: - Outcome-learning advisory

        var adjustmentAdvisory: MealAdjustmentAdvisory?

        /// Recompute the "last time this meal..." advisory from the current totals.
        /// Read-only against the meal log; never edits the carb estimate.
        func refreshAdvisory() {
            let name = runningTotals.name
                ?? detectedFoods.first(where: { !$0.isRemoved })?.name
                ?? ""
            adjustmentAdvisory = MealLog.shared.adjustmentAdvisory(
                forName: name,
                currentCarbs: runningTotals.carbs
            )
        }

        // MARK: - Pre-meal prediction

        var predictedDetermination: Determination?
        var isPredicting = false
        var showPrediction = false

        /// User's glucose unit, passed to the projection chart.
        var glucoseUnits: GlucoseUnits { provider.glucoseUnits }

        /// Projects how the scanned carbs would move glucose, using Trio's own
        /// loop model. Carbs-only (no manual bolus) so it answers "what will this
        /// meal do to me" before dosing. Read-only — never enacts anything.
        @MainActor func previewImpact() async {
            let carbs = runningTotals.carbs
            guard carbs > 0 else { return }
            isPredicting = true
            predictedDetermination = await provider.predictMeal(carbs: carbs, bolus: 0)
            isPredicting = false
            showPrediction = true
        }

        // MARK: - Camera

        func capturePhoto(_ image: UIImage) {
            capturedImage = image
            phase = .analyzing
            Task {
                await analyzeImage()
            }
        }

        // MARK: - Analysis

        @MainActor private func analyzeImage() async {
            guard capturedImage != nil else { return }

            // FatSecret removed — the AI does vision-only analysis (same as Scan Plate).
            detectedFoods = []
            runningTotals = .zero
            refreshAdvisory()
            phase = .chat

            // Start Claude session to analyze the photo directly.
            await startClaudeSession()
        }

        @MainActor private func startClaudeSession() async {
            guard let image = capturedImage else { return }

            do {
                isStreaming = true
                let customNotes = provider.fetchCustomFoodNotes()
                let stream = try await provider.startChatSession(
                    image: image,
                    detectedFoods: detectedFoods,
                    customFoodNotes: customNotes
                )

                var assistantText = ""
                var message = ChatMessage(role: .assistant, text: "")
                chatMessages.append(message)
                let messageIndex = chatMessages.count - 1

                for await chunk in stream {
                    assistantText += chunk
                    chatMessages[messageIndex].text = BaseClaudeNutritionService.conversationalText(from: assistantText)
                }

                // Parse totals from Claude's response
                if let totals = BaseClaudeNutritionService.parseTotals(from: assistantText) {
                    chatMessages[messageIndex].updatedTotals = totals
                    runningTotals = totals
                    refreshAdvisory()
                }

                isStreaming = false

            } catch {
                isStreaming = false
                // Claude failure is non-fatal — user can still use FatSecret results
                let errorMsg = ChatMessage(
                    role: .assistant,
                    text: "I wasn't able to connect for a detailed review. You can still use the scan results above, or type corrections below."
                )
                chatMessages.append(errorMsg)
            }
        }

        // MARK: - Chat

        @MainActor func sendMessage() async {
            let text = userInput.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, !isStreaming else { return }

            let userMessage = ChatMessage(role: .user, text: text)
            chatMessages.append(userMessage)
            userInput = ""

            do {
                isStreaming = true
                let stream = try await provider.sendChatMessage(text)

                var assistantText = ""
                var message = ChatMessage(role: .assistant, text: "")
                chatMessages.append(message)
                let messageIndex = chatMessages.count - 1

                for await chunk in stream {
                    assistantText += chunk
                    chatMessages[messageIndex].text = BaseClaudeNutritionService.conversationalText(from: assistantText)
                }

                if let totals = BaseClaudeNutritionService.parseTotals(from: assistantText) {
                    chatMessages[messageIndex].updatedTotals = totals
                    runningTotals = totals
                    refreshAdvisory()
                }

                isStreaming = false

            } catch {
                isStreaming = false
                errorMessage = error.localizedDescription
                showError = true
            }
        }

        // MARK: - Food List Editing

        func removeFood(at index: Int) {
            guard detectedFoods.indices.contains(index) else { return }
            detectedFoods[index].isRemoved = true
            runningTotals = NutritionTotals.from(detectedFoods)
            refreshAdvisory()
        }

        func restoreFood(at index: Int) {
            guard detectedFoods.indices.contains(index) else { return }
            detectedFoods[index].isRemoved = false
            runningTotals = NutritionTotals.from(detectedFoods)
            refreshAdvisory()
        }

        // MARK: - Confirm

        func confirm() {
            provider.storeFoodIds(from: detectedFoods)
            onConfirm?(runningTotals)
            phase = .confirming
        }

        func cancel() {
            provider.resetChat()
            capturedImage = nil
        }
    }
}
