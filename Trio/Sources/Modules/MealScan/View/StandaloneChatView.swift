import CoreData
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
        @State private var showCamera = false
        @State private var showLibrary = false
        @State private var showBarcode = false
        @State private var showLabel = false

        var onConfirm: ((NutritionTotals) -> Void)? = nil
        /// Re-evaluated on every message so dosing advice always uses live numbers.
        var mealContextProvider: (() -> MealContext?)? = nil
        /// True when shown as a tab (not a modal) — hides the Close button.
        var embedded: Bool = false

        var body: some View {
            NavigationStack {
                messageList
                    .safeAreaInset(edge: .top, spacing: 0) {
                        if let totals = session.current.runningTotals {
                            VStack(spacing: 0) {
                                totalsBar(totals)
                                Divider()
                            }
                        }
                    }
                    // Bottom bar lives in a safe-area inset so the keyboard
                    // pushes it up instead of covering it (fixes invisible typing).
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        VStack(spacing: 0) {
                            if session.current.runningTotals != nil {
                                actionButtons
                            }
                            inputBar
                        }
                        .background(.bar)
                    }
                    .background(Color(.systemBackground))
                    .navigationTitle("Trio Assistant")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        if !embedded {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Close") { dismiss() }
                            }
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
            .onAppear {
                session.configure(resolver: resolver)
                session.mealContextProvider = mealContextProvider
                session.dataContextProvider = { buildAssistantData() }
            }
        }

        /// One-time coaching snapshot for the assistant: full Trio settings + algorithm
        /// preferences. Live glucose/IOB/COB come via the meal context each turn.
        private func buildAssistantData() -> String? {
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
            if let history = recentHistorySummary() {
                parts.append(history)
            }
            if let decisions = algorithmDecisions() {
                parts.append(decisions)
            }
            return parts.isEmpty ? nil : "MY TRIO DATA (for coaching questions):\n\n" + parts.joined(separator: "\n\n")
        }

        /// Trio's own loop decisions over the last 24h: per cycle the predicted
        /// eventualBG, IOB, COB, the temp basal/SMB it chose, and the oref `reason`
        /// string — i.e. WHY it did what it did. This is what lets the assistant
        /// explain the algorithm instead of guessing.
        private func algorithmDecisions() -> String? {
            let since = Date().addingTimeInterval(-24 * 3600)
            let req: NSFetchRequest<OrefDetermination> = OrefDetermination.fetchRequest()
            req.predicate = NSPredicate(format: "deliverAt >= %@", since as NSDate)
            req.sortDescriptors = [NSSortDescriptor(key: "deliverAt", ascending: true)]
            guard let dets = try? moc.fetch(req), !dets.isEmpty else { return nil }
            let stamp = DateFormatter()
            stamp.dateFormat = "EEE HH:mm"
            var lines: [String] = []
            var lastT: Date?
            for d in dets {
                guard let t = d.deliverAt else { continue }
                if let lt = lastT, t.timeIntervalSince(lt) < 28 * 60 { continue } // ~30 min
                lastT = t
                let evbg = d.eventualBG.map { "\($0)" } ?? "?"
                let iob = d.iob.map { "\($0)" } ?? "?"
                let basal = d.tempBasal.map { "\($0)U/hr" } ?? "?"
                let smb = d.smbToDeliver.map { ", SMB \($0)U" } ?? ""
                var reason = d.reason ?? ""
                if reason.count > 240 { reason = String(reason.prefix(240)) + "…" }
                lines
                    .append(
                        "\(stamp.string(from: t)): eventualBG \(evbg), IOB \(iob), COB \(d.cob), basal \(basal)\(smb) — \(reason)"
                    )
            }
            return lines.isEmpty ? nil
                :
                "TRIO ALGORITHM DECISIONS (last 24h, ~30 min apart — the loop's predicted eventualBG, IOB, COB, the basal/SMB it set, and its own reason for each decision):\n"
                + lines.joined(separator: "\n")
        }

        /// Glucose + treatment history from the phone's database: the FULL on-device
        /// history as per-day summaries (TIR/avg/lows, carbs, insulin), plus a detailed
        /// last-48h minute-level timeline. (The phone only retains so much; anything
        /// older than that lives in Nightscout.)
        private func recentHistorySummary() -> String? {
            let cal = Calendar.current
            let now = Date()
            let since48 = now.addingTimeInterval(-48 * 3600)
            let dayfmt = DateFormatter()
            dayfmt.dateFormat = "EEE MMM d"
            let stamp = DateFormatter()
            stamp.dateFormat = "EEE HH:mm"
            var out: [String] = []

            let sm = resolver.resolve(SettingsManager.self)
            let lowT = sm.map { Int(truncating: $0.settings.low as NSNumber) } ?? 70
            let highT = sm.map { Int(truncating: $0.settings.high as NSNumber) } ?? 180

            // Glucose: ALL history on the phone as daily summaries + detailed 48h.
            // Lightweight dictionary fetch keeps this fast even with months of data.
            let gReq = NSFetchRequest<NSDictionary>(entityName: "GlucoseStored")
            gReq.resultType = .dictionaryResultType
            gReq.propertiesToFetch = ["date", "glucose"]
            gReq.sortDescriptors = [NSSortDescriptor(key: "date", ascending: true)]
            if let rows = try? moc.fetch(gReq) {
                let pts: [(Date, Int)] = rows.compactMap { dict in
                    guard let d = dict["date"] as? Date, let g = (dict["glucose"] as? NSNumber)?.intValue else { return nil }
                    return (d, g)
                }
                if !pts.isEmpty {
                    let byDay = Dictionary(grouping: pts) { cal.startOfDay(for: $0.0) }
                    let dailyLines = byDay.keys.sorted().compactMap { day -> String? in
                        let vals = byDay[day]!.map(\.1)
                        guard !vals.isEmpty else { return nil }
                        let avg = vals.reduce(0, +) / vals.count
                        let tir = Int(Double(vals.filter { $0 >= lowT && $0 <= highT }.count) / Double(vals.count) * 100)
                        let lows = vals.filter { $0 < lowT }.count
                        let highs = vals.filter { $0 > highT }.count
                        return "\(dayfmt.string(from: day)): avg \(avg), min \(vals.min()!), max \(vals.max()!), TIR \(tir)%, \(lows) lows, \(highs) highs"
                    }
                    if !dailyLines.isEmpty {
                        out.append(
                            "GLUCOSE daily summary — full on-device history (\(dailyLines.count) days, range \(lowT)-\(highT) mg/dL):\n"
                                + dailyLines.joined(separator: "\n")
                        )
                    }
                    var sampled: [(Date, Int)] = []
                    var lastT: Date?
                    for p in pts where p.0 >= since48 {
                        if let lt = lastT, p.0.timeIntervalSince(lt) < 14 * 60 { continue }
                        sampled.append(p)
                        lastT = p.0
                    }
                    if !sampled.isEmpty {
                        let timeline = sampled.map { "\(stamp.string(from: $0.0)) \($0.1)" }.joined(separator: ", ")
                        out.append("GLUCOSE detailed (last 48h, ~15 min): \(timeline)")
                    }
                }
            }

            // Boluses: all-time total + detailed 48h.
            let bReq: NSFetchRequest<BolusStored> = BolusStored.fetchRequest()
            if let boluses = try? moc.fetch(bReq) {
                let entries = boluses.compactMap { b -> (Date, Decimal)? in
                    guard let t = b.pumpEvent?.timestamp, let amt = b.amount?.decimalValue else { return nil }
                    return (t, amt)
                }.sorted { $0.0 < $1.0 }
                if !entries.isEmpty {
                    let total = entries.reduce(Decimal(0)) { $0 + $1.1 }
                    out.append("INSULIN: \(entries.count) boluses on record, total \(total)U.")
                    let recent = entries.filter { $0.0 >= since48 }.map { "\(stamp.string(from: $0.0)) \($0.1)U" }
                    if !recent.isEmpty { out.append("BOLUSES (last 48h): " + recent.joined(separator: ", ")) }
                }
            }

            // Carbs: all-time total + detailed 48h.
            let cReq: NSFetchRequest<CarbEntryStored> = CarbEntryStored.fetchRequest()
            if let carbs = try? moc.fetch(cReq) {
                let entries = carbs.compactMap { c -> (Date, Int)? in
                    c.date.map { ($0, Int(c.carbs)) }
                }.sorted { $0.0 < $1.0 }
                if !entries.isEmpty {
                    let total = entries.reduce(0) { $0 + $1.1 }
                    out.append("CARBS: \(entries.count) entries on record, total \(total)g.")
                    let recent = entries.filter { $0.0 >= since48 }.map { "\(stamp.string(from: $0.0)) \($0.1)g" }
                    if !recent.isEmpty { out.append("CARBS (last 48h): " + recent.joined(separator: ", ")) }
                }
            }

            return out.isEmpty ? nil : "MY GLUCOSE & TREATMENT HISTORY:\n\n" + out.joined(separator: "\n\n")
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
                            // Don't render blank assistant bubbles (streaming placeholder is
                            // covered by the typing indicator; orphaned empties are hidden).
                            if !(message.role == .assistant && message.text.isEmpty) {
                                messageRow(message, isLastInRun: isLastInRun(at: index))
                                    .id(message.id)
                            }
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
                Text("Trio Assistant")
                    .font(.headline)
                Text(
                    "Estimate a meal (tap ➕ for photo, barcode, or label) — or ask me anything about your settings, glucose trends, or dosing. I can see your Trio setup."
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            }
            .padding(.vertical, 60)
            .frame(maxWidth: .infinity)
        }

        // MARK: - Message row

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

                if let totals = message.updatedTotals, !isUser {
                    macroChips(totals)
                        .padding(.leading, 6)
                        .padding(.top, 2)
                }
            }
            .padding(.top, isLastInRun ? 4 : 1)
        }

        /// Render the assistant's markdown (bold, code, links, line breaks) as rich
        /// text instead of showing raw ** and backticks.
        private func rendered(_ s: String) -> AttributedString {
            (try? AttributedString(markdown: s, options: .init(
                allowsExtendedAttributes: true,
                interpretedSyntax: .inlineOnlyPreservingWhitespace,
                failurePolicy: .returnPartiallyParsedIfPossible
            ))) ?? AttributedString(s)
        }

        @ViewBuilder private func bubble(_ message: ChatMessage, isUser: Bool, isLastInRun: Bool) -> some View {
            let textColor: Color = isUser ? .white : .primary
            let bubbleColor: Color = isUser
                ? Color(red: 0.0, green: 0.48, blue: 1.0)
                : Color(.systemGray5)

            Text(rendered(message.text.isEmpty ? " " : message.text))
                .font(.body)
                .foregroundStyle(textColor)
                .tint(isUser ? .white : Color(red: 0.0, green: 0.48, blue: 1.0))
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
                        MealLog.shared.add(
                            name: totals.name ?? session.current.title,
                            carbs: totals.carbs, fat: totals.fat, protein: totals.protein,
                            source: "chat"
                        )
                        if let onConfirm {
                            // Opened from the Add Treatment screen — apply to the form there.
                            onConfirm(totals)
                            dismiss()
                        } else {
                            // Opened from the Coach tab — no form here, so stash the numbers
                            // and open Add Treatment, which applies them on appear.
                            MealChatSession.pendingApplyTotals = totals
                            resolver.resolve(Router.self)?.mainModalScreen.send(.treatmentView)
                        }
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

        @ViewBuilder private var inputBar: some View {
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
                    Menu {
                        Button { showCamera = true } label: { Label("Take Photo", systemImage: "camera") }
                        Button { showLibrary = true } label: { Label("Photo Library", systemImage: "photo.on.rectangle") }
                        Button { showBarcode = true } label: { Label("Scan Barcode", systemImage: "barcode.viewfinder") }
                        Button { showLabel = true } label: { Label("Nutrition Label", systemImage: "doc.text.viewfinder") }
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 26))
                            .foregroundStyle(session.isStreaming ? Color(.systemGray3) : .blue)
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
            .photosPicker(isPresented: $showLibrary, selection: $photoPickerItem, matching: .images)
            .fullScreenCover(isPresented: $showCamera) {
                CameraCaptureView(
                    onImageCaptured: { img in
                        session.pendingImage = img
                        showCamera = false
                    },
                    onCancel: { showCamera = false }
                )
                .ignoresSafeArea()
            }
            .sheet(isPresented: $showBarcode) {
                MealScan.BarcodeScanView(resolver: resolver, onConfirm: { totals in
                    applyScannedTotals(totals)
                    showBarcode = false
                })
            }
            .sheet(isPresented: $showLabel) {
                MealScan.NutritionLabelScanView(resolver: resolver, onSaved: { _ in showLabel = false })
            }
        }

        /// Feed a barcode/label scan straight into the conversation so the advisor is
        /// the single place all capture methods land.
        private func applyScannedTotals(_ totals: NutritionTotals) {
            session.current.runningTotals = totals
            let c = NSDecimalNumber(decimal: totals.carbs).intValue
            let f = NSDecimalNumber(decimal: totals.fat).intValue
            let p = NSDecimalNumber(decimal: totals.protein).intValue
            session.current.messages.append(ChatMessage(
                role: .assistant,
                text: "📷 \(totals.name ?? "Scanned item"): about \(c)g carbs, \(f)g fat, \(p)g protein. Tap “Use These Numbers” below, or tell me what to adjust.",
                updatedTotals: totals
            ))
            session.current.updatedAt = Date()
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

        @MainActor private func loadPickedImage(_ item: PhotosPickerItem?) async {
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
