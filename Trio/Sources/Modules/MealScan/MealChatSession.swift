import Foundation
import Observation
import Swinject
import UIKit

/// One AI Meal Advisor conversation.
struct MealConversation: Codable, Identifiable {
    var id: UUID
    var messages: [ChatMessage]
    var runningTotals: NutritionTotals?
    var threadId: String?
    var createdAt: Date
    var updatedAt: Date

    init(id: UUID = UUID(), messages: [ChatMessage] = [], runningTotals: NutritionTotals? = nil, threadId: String? = nil) {
        self.id = id
        self.messages = messages
        self.runningTotals = runningTotals
        self.threadId = threadId
        let now = Date()
        createdAt = now
        updatedAt = now
    }

    var isEmpty: Bool { messages.isEmpty }

    /// Short title from the first user message, for the history list.
    var title: String {
        if let firstUser = messages.first(where: { $0.role == .user }) {
            let trimmed = firstUser.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == "📷 Photo" { return "Photo chat" }
            return trimmed.isEmpty ? "Photo chat" : String(trimmed.prefix(42))
        }
        return "New chat"
    }
}

/// Holds the active AI Meal Advisor conversation plus a history of past ones.
///
/// Opening the chat starts a fresh conversation by default; the previous one is
/// archived to history and can be revisited. Everything is a long-lived
/// singleton (survives the sheet closing and app backgrounding) and persists to
/// UserDefaults (survives app relaunch). Codex threads live server-side on the
/// Mac mini, so resuming by id replays full context.
@Observable final class MealChatSession {
    static let shared = MealChatSession()

    var current = MealConversation()
    var history: [MealConversation] = []

    var draftInput: String = ""
    var isStreaming: Bool = false

    /// Image staged for the next outgoing message. Observed but not persisted.
    var pendingImage: UIImage?

    /// Returns a FRESH physiology snapshot (BG/IOB/COB/trend/ISF/CR). Re-evaluated
    /// on every send so the AI never reasons from stale numbers, and reused to
    /// sanity-check the AI's advisory dose arithmetic.
    /// Carbs/fat/protein the user accepted in the Coach-tab assistant ("Use These
    /// Numbers"), waiting to be applied when the Add Treatment screen opens.
    @ObservationIgnored static var pendingApplyTotals: NutritionTotals?

    @ObservationIgnored var mealContextProvider: (() -> MealContext?)?

    /// Full coaching snapshot (settings + therapy + recent data) sent once on the
    /// first turn, so the one assistant can coach on real numbers, not just food.
    @ObservationIgnored var dataContextProvider: (() -> String?)?

    @ObservationIgnored private var provider: MealScan.MealScanProvider?

    private let defaults = UserDefaults.standard
    private let storeKey = "mealChatStore.v2"
    private let historyLimit = 30

    var hasConversation: Bool { !current.isEmpty }

    private init() {
        load()
    }

    /// Call when the chat sheet appears. Reattaches the provider and starts a
    /// fresh conversation by default (archiving whatever was open).
    func configure(resolver: Resolver) {
        if provider == nil {
            provider = MealScan.MealScanProvider(resolver: resolver)
        }
        startNew()
    }

    /// Archive the current conversation (if it has messages) and begin a blank one.
    func startNew() {
        archiveCurrentIfNeeded()
        current = MealConversation()
        draftInput = ""
        pendingImage = nil
        provider?.chatThreadId = nil
        provider?.resetChat()
        save()
    }

    /// Load a past conversation back into the active slot.
    func resume(_ conversation: MealConversation) {
        archiveCurrentIfNeeded()
        history.removeAll { $0.id == conversation.id }
        current = conversation
        draftInput = ""
        pendingImage = nil
        provider?.chatThreadId = conversation.threadId
        provider?.resetChat()
        save()
    }

    func deleteHistory(_ conversation: MealConversation) {
        history.removeAll { $0.id == conversation.id }
        save()
    }

    private func archiveCurrentIfNeeded() {
        guard !current.isEmpty else { return }
        history.removeAll { $0.id == current.id }
        history.insert(current, at: 0)
        if history.count > historyLimit {
            history = Array(history.prefix(historyLimit))
        }
    }

    @MainActor func send() async {
        guard let provider else { return }
        let trimmed = draftInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let image = pendingImage
        guard !trimmed.isEmpty || image != nil else { return }
        guard !isStreaming else { return }

        let isFirstTurn = current.messages.isEmpty
        let context = mealContextProvider?()

        current.messages.append(ChatMessage(role: .user, text: trimmed.isEmpty ? "📷 Photo" : trimmed))
        current.updatedAt = Date()
        draftInput = ""
        pendingImage = nil
        isStreaming = true
        save()

        // Ask iOS for extra execution time so a quick minimize doesn't instantly kill
        // an in-flight reply. (A long background still gets suspended by the OS.)
        let bgTask = UIApplication.shared.beginBackgroundTask(withName: "TrioAssistantChat")
        defer { UIApplication.shared.endBackgroundTask(bgTask) }

        do {
            // Fresh live numbers on every turn; meal-outcome history only on the first.
            var contextParts: [String] = []
            if let block = context?.promptBlock, !block.isEmpty { contextParts.append(block) }
            // Settings + recent glucose/treatment history refreshed every turn so the
            // assistant always answers from current data (not a stale opening snapshot).
            if let data = dataContextProvider?(), !data.isEmpty { contextParts.append(data) }
            if isFirstTurn {
                let outcomes = MealLog.shared.outcomesSummary()
                if !outcomes.isEmpty { contextParts.append(outcomes) }
            }
            let contextBlock = contextParts.isEmpty ? nil : contextParts.joined(separator: "\n\n")

            let stream: AsyncStream<String> = isFirstTurn
                ? try await provider.startFreeFormChat(initialMessage: trimmed, image: image, contextBlock: contextBlock)
                : try await provider.sendChatMessage(trimmed, image: image, contextBlock: contextBlock)

            current.messages.append(ChatMessage(role: .assistant, text: ""))
            let idx = current.messages.count - 1
            var assistantText = ""

            for await chunk in stream {
                assistantText += chunk
                current.messages[idx].text = BaseClaudeNutritionService.conversationalText(from: assistantText)
            }

            if assistantText.isEmpty {
                current.messages[idx].text = "I didn't get a response. Try again."
            } else if let totals = BaseClaudeNutritionService.parseTotals(from: assistantText) {
                current.messages[idx].updatedTotals = totals
                current.runningTotals = totals
                // If the model gave only the block, keep the bubble from being blank.
                if current.messages[idx].text.isEmpty {
                    current.messages[idx].text = "Here's my estimate 👇"
                }

                // Cross-check the AI's dose arithmetic against the same formula in Swift.
                if let aiDose = totals.advisoryDose, let ctx = context {
                    let netCarbs = totals.netCarbs > 0 ? totals.netCarbs : totals.carbs
                    if let swiftDose = ctx.advisoryDose(netCarbs: netCarbs) {
                        let diff = abs(NSDecimalNumber(decimal: aiDose - swiftDose).doubleValue)
                        if diff > 0.5 {
                            let fmt = { (d: Decimal) in
                                NSDecimalNumber(decimal: d).doubleValue.formatted(.number.precision(.fractionLength(1)))
                            }
                            current.messages.append(ChatMessage(
                                role: .assistant,
                                text: "⚠️ Dose check: my math says \(fmt(aiDose))u but the formula gives \(fmt(swiftDose))u with the same numbers. Trust Trio's own calculator over both."
                            ))
                        }
                    }
                }
            }

            // Never leave a blank bubble (reply stripped to nothing, or stream cut short).
            if current.messages[idx].text.isEmpty {
                current.messages[idx].text = "I didn't get a readable reply — tap send to try again."
            }

            current.threadId = provider.chatThreadId
            current.updatedAt = Date()
            isStreaming = false
            save()
        } catch {
            isStreaming = false
            if let last = current.messages.last, last.role == .assistant, last.text.isEmpty {
                current.messages[current.messages.count - 1].text = "Something went wrong. Tap send to retry."
            } else {
                current.messages.append(ChatMessage(role: .assistant, text: "Something went wrong. Tap send to retry."))
            }
            save()
        }
    }

    // MARK: - Persistence

    private struct Store: Codable {
        var current: MealConversation
        var history: [MealConversation]
        var draftInput: String
    }

    private func save() {
        let store = Store(current: current, history: history, draftInput: draftInput)
        if let data = try? JSONEncoder().encode(store) {
            defaults.set(data, forKey: storeKey)
        }
    }

    private func load() {
        guard let data = defaults.data(forKey: storeKey),
              let store = try? JSONDecoder().decode(Store.self, from: data)
        else { return }
        current = store.current
        history = store.history
        draftInput = store.draftInput
    }
}
