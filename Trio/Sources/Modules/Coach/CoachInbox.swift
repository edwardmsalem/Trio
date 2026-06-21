import Foundation
import Observation

/// One advisory note the coach has written for the user (a therapy-settings
/// suggestion with reasoning). Read-only from the phone's side — notes arrive
/// from the coach's notes feed and are never edited or "applied" here.
struct CoachNote: Codable, Identifiable {
    let id: String
    let date: Date
    let title: String
    let body: String
}

/// Holds the live Coach conversation plus the inbox of advisory notes, and
/// persists both to UserDefaults so they survive the sheet closing and an app
/// relaunch. Mirrors `MealChatSession`: a long-lived `@Observable` singleton
/// driving an iMessage-style chat, with the coach's `thread_id` stored so the
/// server-side agent keeps full cross-session memory.
///
/// ADVISORY ONLY: this object never applies a setting and never doses.
@Observable final class CoachInbox {
    static let shared = CoachInbox()

    /// Chat transcript with the coach.
    var messages: [ChatMessage] = []

    /// Advisory notes from the coach, kept newest first.
    var notes: [CoachNote] = []

    var draftInput: String = ""
    var isStreaming: Bool = false

    /// Opaque cursor for the notes feed; pages only the new notes on each fetch.
    @ObservationIgnored var notesCursor: String?

    @ObservationIgnored private let service = CoachService()

    private let defaults = UserDefaults.standard
    private let storeKey = "coachStore.v1"

    var hasConversation: Bool { !messages.isEmpty }

    private init() {
        load()
        service.threadId = persistedThreadId
    }

    // MARK: - Chat

    @MainActor func send() async {
        let trimmed = draftInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isStreaming else { return }

        messages.append(ChatMessage(role: .user, text: trimmed))
        draftInput = ""
        isStreaming = true
        save()

        do {
            let stream = try await service.send(trimmed)

            messages.append(ChatMessage(role: .assistant, text: ""))
            let idx = messages.count - 1
            var assistantText = ""

            for await chunk in stream {
                assistantText += chunk
                messages[idx].text = assistantText
            }

            if assistantText.isEmpty {
                messages[idx].text = "I didn't get a response. Try again."
            }

            persistedThreadId = service.threadId
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

    /// Clears the on-device transcript and starts a fresh server-side thread.
    func startNew() {
        messages = []
        draftInput = ""
        service.resetThread()
        persistedThreadId = nil
        save()
    }

    // MARK: - Notes

    /// Pulls any new advisory notes from the coach and merges them in (newest
    /// first, de-duplicated by id). Safe to call on foreground.
    @MainActor func refreshNotes() async {
        do {
            let result = try await service.fetchNotes(since: notesCursor)
            guard !result.notes.isEmpty || result.cursor != nil else { return }

            var byId = Dictionary(notes.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
            for note in result.notes {
                byId[note.id] = note
            }
            notes = byId.values.sorted { $0.date > $1.date }

            if let cursor = result.cursor {
                notesCursor = cursor
            }
            save()
        } catch {
            debug(.default, "[coach] notes fetch failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Persistence

    @ObservationIgnored private var persistedThreadId: String?

    private struct Store: Codable {
        var messages: [ChatMessage]
        var notes: [CoachNote]
        var draftInput: String
        var threadId: String?
        var notesCursor: String?
    }

    private func save() {
        let store = Store(
            messages: messages,
            notes: notes,
            draftInput: draftInput,
            threadId: persistedThreadId,
            notesCursor: notesCursor
        )
        if let data = try? JSONEncoder().encode(store) {
            defaults.set(data, forKey: storeKey)
        }
    }

    private func load() {
        guard let data = defaults.data(forKey: storeKey),
              let store = try? JSONDecoder().decode(Store.self, from: data)
        else { return }
        messages = store.messages
        notes = store.notes
        draftInput = store.draftInput
        persistedThreadId = store.threadId
        notesCursor = store.notesCursor
    }
}
