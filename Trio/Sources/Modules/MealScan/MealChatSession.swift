import Foundation
import Observation
import Swinject
import UIKit

/// Holds the AI Meal Advisor conversation so it survives the chat sheet being
/// dismissed, the app being backgrounded, and a full app relaunch.
///
/// Minimize/restore is covered by this being a long-lived singleton (the
/// conversation lives outside the transient SwiftUI view). App-kill is covered
/// by persisting messages + the Codex thread id to UserDefaults; the Codex
/// thread itself lives server-side (Mac-mini ~/.codex/sessions) so resuming by
/// id replays full context.
@Observable
final class MealChatSession {
    static let shared = MealChatSession()

    var messages: [ChatMessage] = []
    var runningTotals: NutritionTotals?
    var draftInput: String = ""
    var isStreaming: Bool = false

    /// Image staged for the next outgoing message. Observed (drives the
    /// attached-photo strip) but never persisted to disk.
    var pendingImage: UIImage?

    @ObservationIgnored private var provider: MealScanProvider?
    @ObservationIgnored private var threadId: String?

    private let defaults = UserDefaults.standard
    private let storeKey = "mealChatSession.v1"

    var hasConversation: Bool { !messages.isEmpty }

    private init() {
        load()
    }

    /// Must be called when a view appears so the session has a resolver-backed
    /// provider and the restored thread id is reattached to a fresh service.
    func configure(resolver: Resolver) {
        if provider == nil {
            provider = MealScanProvider(resolver: resolver)
        }
        provider?.chatThreadId = threadId
    }

    @MainActor
    func send() async {
        guard let provider else { return }
        let trimmed = draftInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let image = pendingImage
        guard !trimmed.isEmpty || image != nil else { return }
        guard !isStreaming else { return }

        let isFirstTurn = messages.isEmpty

        messages.append(ChatMessage(role: .user, text: trimmed.isEmpty ? "📷 Photo" : trimmed))
        draftInput = ""
        pendingImage = nil
        isStreaming = true
        save()

        do {
            let stream: AsyncStream<String> = isFirstTurn
                ? try await provider.startFreeFormChat(initialMessage: trimmed, image: image)
                : try await provider.sendChatMessage(trimmed)

            messages.append(ChatMessage(role: .assistant, text: ""))
            let idx = messages.count - 1
            var assistantText = ""

            for await chunk in stream {
                assistantText += chunk
                messages[idx].text = assistantText
            }

            if assistantText.isEmpty {
                messages[idx].text = "I didn't get a response. Try again."
            } else if let totals = BaseClaudeNutritionService.parseTotals(from: assistantText) {
                messages[idx].updatedTotals = totals
                runningTotals = totals
            }

            threadId = provider.chatThreadId
            isStreaming = false
            save()
        } catch {
            isStreaming = false
            if let last = messages.last, last.role == .assistant, last.text.isEmpty {
                messages[messages.count - 1].text = "Something went wrong. Tap send to retry."
            } else {
                messages.append(ChatMessage(role: .assistant, text: "Something went wrong. Tap send to retry."))
            }
            save()
        }
    }

    func reset() {
        messages = []
        runningTotals = nil
        draftInput = ""
        pendingImage = nil
        threadId = nil
        provider?.chatThreadId = nil
        provider?.resetChat()
        defaults.removeObject(forKey: storeKey)
    }

    // MARK: - Persistence

    private struct Persisted: Codable {
        var messages: [ChatMessage]
        var runningTotals: NutritionTotals?
        var threadId: String?
        var draftInput: String
    }

    private func save() {
        let snapshot = Persisted(
            messages: messages,
            runningTotals: runningTotals,
            threadId: threadId,
            draftInput: draftInput
        )
        if let data = try? JSONEncoder().encode(snapshot) {
            defaults.set(data, forKey: storeKey)
        }
    }

    private func load() {
        guard let data = defaults.data(forKey: storeKey),
              let snapshot = try? JSONDecoder().decode(Persisted.self, from: data)
        else { return }
        messages = snapshot.messages
        runningTotals = snapshot.runningTotals
        threadId = snapshot.threadId
        draftInput = snapshot.draftInput
    }
}
