import SwiftUI
import Swinject

extension Coach {
    /// The Trio Coach surface: an iMessage-style advisory chat plus an inbox of
    /// the coach's written suggestions. Mirrors `MealScan.StandaloneChatView`
    /// minus camera/nutrition/totals/confirm, with a permanent advisory banner.
    ///
    /// ADVISORY ONLY: there is no Apply button and no dose action anywhere here.
    struct CoachView: View {
        let resolver: Resolver
        /// When shown as a tab (not a modal sheet) there's nothing to dismiss, so
        /// the Close button is hidden.
        var embedded: Bool = false

        @Environment(\.dismiss) var dismiss

        @State private var state = StateModel()
        @State private var revealedTimestampID: UUID?
        @State private var expandedNoteID: String?

        /// Bindable handle to the shared inbox so the input field can two-way bind
        /// to `draftInput`. Same singleton `state.inbox` points at.
        @Bindable private var inbox = CoachInbox.shared

        var body: some View {
            NavigationStack {
                content
                    // Non-dismissible advisory banner, pinned above everything.
                    .safeAreaInset(edge: .top, spacing: 0) {
                        advisoryBanner
                    }
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        if state.selectedTab == .chat {
                            inputBar
                                .background(.bar)
                        }
                    }
                    .background(Color(.systemBackground))
                    .navigationTitle("Trio Coach")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        if !embedded {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Close") { dismiss() }
                            }
                        }
                        ToolbarItem(placement: .principal) {
                            Picker("View", selection: $state.selectedTab) {
                                ForEach(StateModel.Tab.allCases) { tab in
                                    Text(tab.displayName).tag(tab)
                                }
                            }
                            .pickerStyle(.segmented)
                            .frame(maxWidth: 220)
                        }
                        ToolbarItem(placement: .primaryAction) {
                            Button {
                                inbox.startNew()
                            } label: {
                                Image(systemName: "square.and.pencil")
                            }
                            .disabled(!inbox.hasConversation || inbox.isStreaming)
                        }
                    }
            }
            .task {
                inbox.contextProvider = { buildCoachContext() }
                await state.onAppear()
            }
        }

        /// One-time data snapshot handed to the coach on the first turn: the user's
        /// full Trio settings + algorithm preferences. Glucose, treatments, and the
        /// therapy profile (basal/ISF/CR/targets) come from Nightscout server-side.
        private func buildCoachContext() -> String? {
            guard let settingsManager = resolver.resolve(SettingsManager.self) else { return nil }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            var parts: [String] = []
            if let data = try? encoder.encode(settingsManager.settings),
               let json = String(data: data, encoding: .utf8)
            {
                parts.append("MY TRIO SETTINGS (JSON):\n\(json)")
            }
            if let data = try? encoder.encode(settingsManager.preferences),
               let json = String(data: data, encoding: .utf8)
            {
                parts.append("MY TRIO ALGORITHM PREFERENCES (JSON):\n\(json)")
            }
            parts.append(
                "My glucose readings, treatment history (carbs, boluses, basal), and therapy profile (basal rates, ISF, carb ratios, targets) are available to you via Nightscout — use them for trends, patterns, and any settings advice."
            )
            return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
        }

        @ViewBuilder private var content: some View {
            switch state.selectedTab {
            case .chat:
                messageList
            case .inbox:
                notesList
            }
        }

        // MARK: - Advisory banner

        private var advisoryBanner: some View {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle.fill")
                        .foregroundStyle(.orange)
                    Text(Coach.advisoryBanner)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.12))
                Divider()
            }
        }

        // MARK: - Chat

        private var messageList: some View {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        if !inbox.hasConversation {
                            emptyChatState
                        }

                        ForEach(Array(inbox.messages.enumerated()), id: \.element.id) { index, message in
                            messageRow(message, isLastInRun: isLastInRun(at: index))
                                .id(message.id)
                        }

                        if inbox.isStreaming, inbox.messages.last?.text.isEmpty ?? false {
                            typingIndicator
                                .id("typing")
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: inbox.messages.last?.text) {
                    if let last = inbox.messages.last {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
        }

        private var emptyChatState: some View {
            VStack(spacing: 12) {
                Image(systemName: "person.fill.questionmark")
                    .font(.system(size: 46))
                    .foregroundStyle(.blue.gradient)
                Text("Trio Coach")
                    .font(.headline)
                Text(
                    "Ask about your basal rates, carb ratio, insulin sensitivity, or targets. The coach reads your history and suggests changes with reasoning — it never applies anything for you."
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            }
            .padding(.vertical, 60)
            .frame(maxWidth: .infinity)
        }

        @ViewBuilder private func messageRow(_ message: ChatMessage, isLastInRun: Bool) -> some View {
            let isUser = message.role == .user

            VStack(alignment: isUser ? .trailing : .leading, spacing: 2) {
                if revealedTimestampID == message.id {
                    Text(message.timestamp, format: .dateTime.hour().minute())
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 2)
                }

                HStack {
                    if isUser { Spacer(minLength: 50) }

                    bubble(message, isUser: isUser, isLastInRun: isLastInRun)
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                revealedTimestampID = revealedTimestampID == message.id ? nil : message.id
                            }
                        }

                    if !isUser { Spacer(minLength: 50) }
                }
            }
            .padding(.top, isLastInRun ? 4 : 1)
        }

        @ViewBuilder private func bubble(_ message: ChatMessage, isUser: Bool, isLastInRun: Bool) -> some View {
            let textColor: Color = isUser ? .white : .primary
            let bubbleColor: Color = isUser
                ? Color(red: 0.0, green: 0.48, blue: 1.0)
                : Color(.systemGray5)

            Text(message.text.isEmpty ? " " : message.text)
                .font(.body)
                .foregroundStyle(textColor)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(
                    Group {
                        if isLastInRun {
                            ChatBubbleShape(direction: isUser ? .right : .left)
                                .fill(bubbleColor)
                        } else {
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(bubbleColor)
                        }
                    }
                )
                .textSelection(.enabled)
        }

        private var typingIndicator: some View {
            HStack {
                HStack(spacing: 4) {
                    ForEach(0 ..< 3) { _ in
                        Circle()
                            .fill(.secondary)
                            .frame(width: 7, height: 7)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(ChatBubbleShape(direction: .left).fill(Color(.systemGray5)))
                Spacer(minLength: 50)
            }
            .padding(.top, 4)
        }

        // MARK: - Notes inbox

        private var notesList: some View {
            Group {
                if inbox.notes.isEmpty {
                    emptyNotesState
                } else {
                    List {
                        ForEach(inbox.notes) { note in
                            noteRow(note)
                        }
                    }
                    .listStyle(.insetGrouped)
                    .refreshable {
                        await inbox.refreshNotes()
                    }
                }
            }
        }

        private var emptyNotesState: some View {
            ContentUnavailableView(
                String(localized: "No suggestions yet"),
                systemImage: "tray",
                description: Text("As the coach reviews your data, its written suggestions will land here.")
            )
        }

        @ViewBuilder private func noteRow(_ note: CoachNote) -> some View {
            let isExpanded = expandedNoteID == note.id

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(note.title.isEmpty ? String(localized: "Suggestion") : note.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Spacer()
                    Text(note.date, format: .dateTime.month().day().hour().minute())
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Text(note.body)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(isExpanded ? nil : 3)
                    .textSelection(.enabled)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.15)) {
                    expandedNoteID = isExpanded ? nil : note.id
                }
            }
        }

        // MARK: - Input bar

        private var inputBar: some View {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    TextField("Ask the coach", text: $inbox.draftInput, axis: .vertical)
                        .lineLimit(1 ... 5)
                        .padding(.leading, 12)
                        .padding(.vertical, 7)

                    Button {
                        Task { await state.send() }
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(sendDisabled ? Color(.systemGray3) : Color(red: 0.0, green: 0.48, blue: 1.0))
                    }
                    .disabled(sendDisabled)
                    .padding(.trailing, 3)
                }
                .overlay(
                    Capsule().stroke(Color(.systemGray4), lineWidth: 1)
                )
                .clipShape(Capsule())
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }

        private var sendDisabled: Bool {
            inbox.isStreaming ||
                inbox.draftInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        // MARK: - Helpers

        private func isLastInRun(at index: Int) -> Bool {
            let messages = inbox.messages
            guard index < messages.count else { return true }
            let next = index + 1
            guard next < messages.count else { return true }
            return messages[next].role != messages[index].role
        }
    }
}
