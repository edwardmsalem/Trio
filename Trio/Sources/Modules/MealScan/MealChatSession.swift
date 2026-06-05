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
@Observable
final class MealChatSession {
    static let shared = MealChatSession()

    var current = MealConversation()
    var history: [MealConversation] = []

    var draftInput: String = ""
    var isStreaming: Bool = false

    /// Image staged for the next outgoing message. Observed but not persisted.
    var pendingImage: UIImage?

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

    @MainActor
    func send() async {
        guard let provider else { return }
        let trimmed = draftInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let image = pendingImage
        guard !trimmed.isEmpty || image != nil else { return }
        guard !isStreaming else { return }

        let isFirstTurn = current.messages.isEmpty

        current.messages.append(ChatMessage(role: .user, text: trimmed.isEmpty ? "📷 Photo" : trimmed))
        current.updatedAt = Date()
        draftInput = ""
        pendingImage = nil
        isStreaming = true
        save()

        do {
            let stream: AsyncStream<String> = isFirstTurn
                ? try await provider.startFreeFormChat(initialMessage: trimmed, image: image)
                : try await provider.sendChatMessage(trimmed)

            current.messages.append(ChatMessage(role: .assistant, text: ""))
            let idx = current.messages.count - 1
            var assistantText = ""

            for await chunk in stream {
                assistantText += chunk
                current.messages[idx].text = assistantText
            }

            if assistantText.isEmpty {
                current.messages[idx].text = "I didn't get a response. Try again."
            } else if let totals = BaseClaudeNutritionService.parseTotals(from: assistantText) {
                current.messages[idx].updatedTotals = totals
                current.runningTotals = totals
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
