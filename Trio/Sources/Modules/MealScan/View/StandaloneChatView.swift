import PhotosUI
import SwiftUI
import Swinject
import UIKit

extension MealScan {
    struct StandaloneChatView: View {
        let resolver: Resolver

        @Environment(\.dismiss) var dismiss

        @State private var provider: MealScanProvider?
        @State private var messages: [ChatMessage] = []
        @State private var userInput: String = ""
        @State private var isStreaming: Bool = false
        @State private var attachedImage: UIImage?
        @State private var photoPickerItem: PhotosPickerItem?
        @State private var hasStarted: Bool = false
        @State private var errorMessage: String?
        @State private var showError = false
        @State private var runningTotals: NutritionTotals?

        var onConfirm: ((NutritionTotals) -> Void)?

        var body: some View {
            NavigationStack {
                VStack(spacing: 0) {
                    if let totals = runningTotals {
                        totalsBar(totals)
                    }

                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 12) {
                                if !hasStarted {
                                    emptyStateView
                                }

                                if let img = attachedImage, !hasStarted {
                                    Image(uiImage: img)
                                        .resizable()
                                        .scaledToFit()
                                        .frame(maxHeight: 200)
                                        .clipShape(RoundedRectangle(cornerRadius: 12))
                                        .padding(.horizontal)
                                }

                                ForEach(messages) { message in
                                    chatBubble(for: message)
                                        .id(message.id)
                                }

                                if isStreaming {
                                    HStack {
                                        ProgressView().scaleEffect(0.8)
                                        Text("Thinking...")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    .padding(.horizontal)
                                }
                            }
                            .padding(.vertical, 8)
                        }
                        .onChange(of: messages.count) {
                            if let last = messages.last {
                                withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                            }
                        }
                    }

                    Divider()

                    inputBar

                    if runningTotals != nil {
                        confirmButton
                    }
                }
                .navigationTitle("AI Meal Advisor")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { dismiss() }
                    }
                }
                .alert("Error", isPresented: $showError) {
                    Button("OK") { showError = false }
                } message: {
                    Text(errorMessage ?? "Something went wrong")
                }
                .onChange(of: photoPickerItem) { _, newValue in
                    Task { await loadPickedImage(newValue) }
                }
            }
            .onAppear {
                if provider == nil {
                    provider = MealScanProvider(resolver: resolver)
                }
            }
        }

        private var emptyStateView: some View {
            VStack(spacing: 12) {
                Image(systemName: "bubble.left.and.text.bubble.right")
                    .font(.system(size: 50))
                    .foregroundStyle(.blue)
                Text("Discuss your meal with AI")
                    .font(.headline)
                Text("Send a message, attach a photo, or both. Ask anything about carbs, fat, protein, or insulin timing.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            .padding(.vertical, 40)
            .frame(maxWidth: .infinity)
        }

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

        private func chatBubble(for message: ChatMessage) -> some View {
            HStack {
                if message.role == .user { Spacer(minLength: 60) }

                VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
                    Text(message.text)
                        .font(.subheadline)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(message.role == .user ? Color.blue.opacity(0.15) : Color(.systemGray5))
                        .clipShape(RoundedRectangle(cornerRadius: 16))

                    if let totals = message.updatedTotals {
                        HStack(spacing: 8) {
                            Text("Updated:").font(.caption2).foregroundStyle(.secondary)
                            Text("C: \(NSDecimalNumber(decimal: totals.carbs).intValue)g").foregroundStyle(.blue)
                            Text("F: \(NSDecimalNumber(decimal: totals.fat).intValue)g").foregroundStyle(.orange)
                            Text("P: \(NSDecimalNumber(decimal: totals.protein).intValue)g").foregroundStyle(.red)
                        }
                        .font(.caption)
                    }
                }

                if message.role == .assistant { Spacer(minLength: 60) }
            }
            .padding(.horizontal)
        }

        private var inputBar: some View {
            VStack(spacing: 8) {
                if let img = attachedImage, hasStarted {
                    HStack {
                        Image(uiImage: img)
                            .resizable().scaledToFill()
                            .frame(width: 40, height: 40)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        Text("Photo attached")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            attachedImage = nil
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal)
                }

                HStack(spacing: 8) {
                    PhotosPicker(selection: $photoPickerItem, matching: .images) {
                        Image(systemName: attachedImage == nil ? "photo.badge.plus" : "photo.fill")
                            .font(.title2)
                            .foregroundStyle(.blue)
                    }
                    .disabled(isStreaming)

                    TextField("Ask the AI...", text: $userInput, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(1 ... 4)
                        .padding(8)
                        .background(Color(.systemGray6))
                        .clipShape(RoundedRectangle(cornerRadius: 20))

                    Button {
                        Task { await sendMessage() }
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.blue)
                    }
                    .disabled(sendDisabled)
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
        }

        private var sendDisabled: Bool {
            isStreaming || (userInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachedImage == nil)
        }

        private var confirmButton: some View {
            Button {
                if let totals = runningTotals {
                    onConfirm?(totals)
                    dismiss()
                }
            } label: {
                Text("Use These Numbers")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.green)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .disabled(isStreaming)
            .padding(.horizontal)
            .padding(.bottom, 8)
        }

        @MainActor
        private func sendMessage() async {
            guard let provider else { return }
            let text = userInput.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty || attachedImage != nil else { return }

            let imageForThisTurn = attachedImage
            let userMsg = ChatMessage(role: .user, text: text.isEmpty ? "[Photo]" : text)
            messages.append(userMsg)
            userInput = ""
            isStreaming = true

            do {
                let stream: AsyncStream<String>
                if !hasStarted {
                    stream = try await provider.startFreeFormChat(initialMessage: text, image: imageForThisTurn)
                    hasStarted = true
                    attachedImage = nil
                } else {
                    if imageForThisTurn != nil {
                        // Subsequent message with photo not yet supported by Claude wrapper
                        // Send as text only; user has been shown the image inline
                        stream = try await provider.sendChatMessage(text)
                        attachedImage = nil
                    } else {
                        stream = try await provider.sendChatMessage(text)
                    }
                }

                var assistantText = ""
                var assistantMsg = ChatMessage(role: .assistant, text: "")
                messages.append(assistantMsg)
                let idx = messages.count - 1

                for await chunk in stream {
                    assistantText += chunk
                    messages[idx].text = assistantText
                }

                if let totals = BaseClaudeNutritionService.parseTotals(from: assistantText) {
                    messages[idx].updatedTotals = totals
                    runningTotals = totals
                }

                isStreaming = false
            } catch {
                isStreaming = false
                errorMessage = error.localizedDescription
                showError = true
            }
        }

        @MainActor
        private func loadPickedImage(_ item: PhotosPickerItem?) async {
            guard let item else { return }
            if let data = try? await item.loadTransferable(type: Data.self),
               let img = UIImage(data: data)
            {
                attachedImage = img
            }
        }
    }
}
