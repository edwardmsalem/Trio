import PhotosUI
import SwiftUI
import Swinject
import UIKit

extension MealScan {
    struct StandaloneChatView: View {
        let resolver: Resolver

        @Environment(\.dismiss) var dismiss
        @Environment(\.colorScheme) private var colorScheme
        @Environment(\.managedObjectContext) private var moc

        @State private var session = MealChatSession.shared
        @State private var photoPickerItem: PhotosPickerItem?
        @State private var revealedTimestampID: UUID?
        @State private var showHistory = false
        @State private var showSavePreset = false
        @State private var presetName = ""

        var onConfirm: ((NutritionTotals) -> Void)?

        var body: some View {
            NavigationStack {
                VStack(spacing: 0) {
                    if let totals = session.current.runningTotals {
                        totalsBar(totals)
                        Divider()
                    }

                    messageList

                    if session.current.runningTotals != nil {
                        actionButtons
                    }

                    inputBar
                }
                .background(Color(.systemBackground))
                .navigationTitle("AI Meal Advisor")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { dismiss() }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        HStack(spacing: 16) {
                            Button {
                                showHistory = true
                            } label: {
                                Image(systemName: "clock.arrow.circlepath")
                            }
                            .disabled(session.history.isEmpty)

                            Button {
                                session.startNew()
                            } label: {
                                Image(systemName: "square.and.pencil")
                            }
                            .disabled(!session.hasConversation || session.isStreaming)
                        }
                    }
                }
                .sheet(isPresented: $showHistory) {
                    historySheet
                }
                .alert("Save as Preset", isPresented: $showSavePreset) {
                    TextField("Preset name", text: $presetName)
                    Button("Save") { savePreset() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Saves the current carbs, fat, and protein as a reusable preset.")
                }
                .onChange(of: photoPickerItem) { _, newValue in
                    Task { await loadPickedImage(newValue) }
                }
            }
            .onAppear { session.configure(resolver: resolver) }
        }

        // MARK: - History

        private var historySheet: some View {
            NavigationStack {
                List {
                    if session.history.isEmpty {
                        Text("No past conversations yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(session.history) { convo in
                            Button {
                                session.resume(convo)
                                showHistory = false
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(convo.title)
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    Text(convo.updatedAt, format: .dateTime.month().day().hour().minute())
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .onDelete { offsets in
                            for i in offsets { session.deleteHistory(session.history[i]) }
                        }
                    }
                }
                .navigationTitle("Past Chats")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { showHistory = false }
                    }
                }
            }
        }

        // MARK: - Message list

        private var messageList: some View {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        if !session.hasConversation {
                            emptyState
                        }

                        ForEach(Array(session.current.messages.enumerated()), id: \.element.id) { index, message in
                            messageRow(message, isLastInRun: isLastInRun(at: index))
                                .id(message.id)
                        }

                        if session.isStreaming, session.current.messages.last?.text.isEmpty ?? false {
                            typingIndicator
                                .id("typing")
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: session.current.messages.last?.text) {
                    if let last = session.current.messages.last {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
        }

        private var emptyState: some View {
            VStack(spacing: 12) {
                Image(systemName: "bubble.left.and.text.bubble.right.fill")
                    .font(.system(size: 46))
                    .foregroundStyle(.blue.gradient)
                Text("AI Meal Advisor")
                    .font(.headline)
                Text("Send a message, attach a photo, or both. Ask about carbs, fat, protein, or insulin timing.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
            .padding(.vertical, 60)
            .frame(maxWidth: .infinity)
        }

        // MARK: - Message row

        @ViewBuilder
        private func messageRow(_ message: ChatMessage, isLastInRun: Bool) -> some View {
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

                if let totals = message.updatedTotals, !isUser {
                    macroChips(totals)
                        .padding(.leading, 6)
                        .padding(.top, 2)
                }
            }
            .padding(.top, isLastInRun ? 4 : 1)
        }

        @ViewBuilder
        private func bubble(_ message: ChatMessage, isUser: Bool, isLastInRun: Bool) -> some View {
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

        private func macroChips(_ totals: NutritionTotals) -> some View {
            HStack(spacing: 6) {
                macroChip("C", value: totals.carbs, color: .blue)
                macroChip("F", value: totals.fat, color: .orange)
                macroChip("P", value: totals.protein, color: .red)
            }
        }

        private func macroChip(_ label: String, value: Decimal, color: Color) -> some View {
            Text("\(label) \(NSDecimalNumber(decimal: value).intValue)g")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(color)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(color.opacity(0.12), in: Capsule())
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

        // MARK: - Totals bar

        private func totalsBar(_ totals: NutritionTotals) -> some View {
            HStack(spacing: 16) {
                totalItem(label: "Carbs", value: totals.carbs, unit: "g", color: .blue)
                totalItem(label: "Fat", value: totals.fat, unit: "g", color: .orange)
                totalItem(label: "Protein", value: totals.protein, unit: "g", color: .red)
                totalItem(label: "Cal", value: totals.calories, unit: "", color: .secondary)
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
            .background(Color(.systemGroupedBackground))
        }

        private func totalItem(label: String, value: Decimal, unit: String, color: Color) -> some View {
            VStack(spacing: 2) {
                Text(label).font(.caption2).foregroundStyle(.secondary)
                Text("\(NSDecimalNumber(decimal: value).intValue)\(unit)")
                    .font(.subheadline).fontWeight(.semibold).foregroundStyle(color)
            }
            .frame(maxWidth: .infinity)
        }

        // MARK: - Confirm

        private var actionButtons: some View {
            HStack(spacing: 10) {
                Button {
                    presetName = session.current.title
                    showSavePreset = true
                } label: {
                    Label("Save Meal", systemImage: "bookmark")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.blue)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(Color.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .disabled(session.isStreaming)

                Button {
                    if let totals = session.current.runningTotals {
                        onConfirm?(totals)
                        dismiss()
                    }
                } label: {
                    Text("Use These Numbers")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(Color.green, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .disabled(session.isStreaming)
            }
            .padding(.horizontal)
            .padding(.bottom, 6)
        }

        private func savePreset() {
            guard let totals = session.current.runningTotals else { return }
            let name = presetName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return }
            let preset = MealPresetStored(context: moc)
            preset.dish = String(name.prefix(25))
            preset.carbs = totals.carbs as NSDecimalNumber
            preset.fat = totals.fat as NSDecimalNumber
            preset.protein = totals.protein as NSDecimalNumber
            try? moc.save()
        }

        // MARK: - Input bar

        @ViewBuilder
        private var inputBar: some View {
            VStack(spacing: 6) {
                if let img = session.pendingImage {
                    HStack {
                        Image(uiImage: img)
                            .resizable().scaledToFill()
                            .frame(width: 44, height: 44)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        Text("Photo attached")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            session.pendingImage = nil
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal)
                    .transition(.opacity)
                }

                HStack(spacing: 8) {
                    PhotosPicker(selection: $photoPickerItem, matching: .images) {
                        Image(systemName: "camera.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(.blue)
                    }
                    .disabled(session.isStreaming)

                    HStack(spacing: 6) {
                        TextField("Message", text: $session.draftInput, axis: .vertical)
                            .lineLimit(1 ... 5)
                            .padding(.leading, 12)
                            .padding(.vertical, 7)

                        Button {
                            Task { await session.send() }
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
            .background(.bar)
        }

        private var sendDisabled: Bool {
            session.isStreaming ||
                (session.draftInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && session.pendingImage == nil)
        }

        // MARK: - Helpers

        private func isLastInRun(at index: Int) -> Bool {
            let messages = session.current.messages
            guard index < messages.count else { return true }
            let next = index + 1
            guard next < messages.count else { return true }
            return messages[next].role != messages[index].role
        }

        @MainActor
        private func loadPickedImage(_ item: PhotosPickerItem?) async {
            guard let item else { return }
            if let data = try? await item.loadTransferable(type: Data.self),
               let img = UIImage(data: data)
            {
                withAnimation { session.pendingImage = img }
            }
        }
    }
}

// MARK: - iMessage bubble shape (with tail on the last bubble of a run)

struct ChatBubbleShape: Shape {
    enum Direction { case left, right }
    let direction: Direction

    func path(in rect: CGRect) -> Path {
        direction == .left ? leftBubble(in: rect) : rightBubble(in: rect)
    }

    private func leftBubble(in rect: CGRect) -> Path {
        let width = rect.width
        let height = rect.height
        return Path { p in
            p.move(to: CGPoint(x: 25, y: height))
            p.addLine(to: CGPoint(x: width - 20, y: height))
            p.addCurve(
                to: CGPoint(x: width, y: height - 20),
                control1: CGPoint(x: width - 8, y: height),
                control2: CGPoint(x: width, y: height - 8)
            )
            p.addLine(to: CGPoint(x: width, y: 20))
            p.addCurve(
                to: CGPoint(x: width - 20, y: 0),
                control1: CGPoint(x: width, y: 8),
                control2: CGPoint(x: width - 8, y: 0)
            )
            p.addLine(to: CGPoint(x: 21, y: 0))
            p.addCurve(
                to: CGPoint(x: 4, y: 20),
                control1: CGPoint(x: 12, y: 0),
                control2: CGPoint(x: 4, y: 8)
            )
            p.addLine(to: CGPoint(x: 4, y: height - 11))
            p.addCurve(
                to: CGPoint(x: 0, y: height),
                control1: CGPoint(x: 4, y: height - 1),
                control2: CGPoint(x: 0, y: height)
            )
            p.addLine(to: CGPoint(x: -0.05, y: height - 0.01))
            p.addCurve(
                to: CGPoint(x: 11.0, y: height - 4.0),
                control1: CGPoint(x: 4.0, y: height + 0.5),
                control2: CGPoint(x: 8, y: height - 1)
            )
            p.addCurve(
                to: CGPoint(x: 25, y: height),
                control1: CGPoint(x: 16, y: height),
                control2: CGPoint(x: 20, y: height)
            )
        }
    }

    private func rightBubble(in rect: CGRect) -> Path {
        let width = rect.width
        let height = rect.height
        return Path { p in
            p.move(to: CGPoint(x: 25, y: height))
            p.addLine(to: CGPoint(x: 20, y: height))
            p.addCurve(
                to: CGPoint(x: 0, y: height - 20),
                control1: CGPoint(x: 8, y: height),
                control2: CGPoint(x: 0, y: height - 8)
            )
            p.addLine(to: CGPoint(x: 0, y: 20))
            p.addCurve(
                to: CGPoint(x: 20, y: 0),
                control1: CGPoint(x: 0, y: 8),
                control2: CGPoint(x: 8, y: 0)
            )
            p.addLine(to: CGPoint(x: width - 21, y: 0))
            p.addCurve(
                to: CGPoint(x: width - 4, y: 20),
                control1: CGPoint(x: width - 12, y: 0),
                control2: CGPoint(x: width - 4, y: 8)
            )
            p.addLine(to: CGPoint(x: width - 4, y: height - 11))
            p.addCurve(
                to: CGPoint(x: width, y: height),
                control1: CGPoint(x: width - 4, y: height - 1),
                control2: CGPoint(x: width, y: height)
            )
            p.addLine(to: CGPoint(x: width + 0.05, y: height - 0.01))
            p.addCurve(
                to: CGPoint(x: width - 11, y: height - 4),
                control1: CGPoint(x: width - 4, y: height + 0.5),
                control2: CGPoint(x: width - 8, y: height - 1)
            )
            p.addCurve(
                to: CGPoint(x: width - 25, y: height),
                control1: CGPoint(x: width - 16, y: height),
                control2: CGPoint(x: width - 20, y: height)
            )
        }
    }
}
