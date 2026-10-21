import Combine
import CoreData
import CryptoKit
import Foundation
import Swinject
import UserNotifications

/// Bolus, carbs and pairing requests from the Garmin Bolus watch app.
///
/// The watch never names a dose to give. It asks for a quote -- carbs, and either an
/// amount or "work it out" -- and Trio prices it with its own bolus calculator and its
/// own limits, keeps the quote, and answers with what it would actually give. The
/// watch shows that figure and the wearer holds to confirm, which sends back only the
/// quote's id. So the amount approved on the wrist is always the amount delivered, and
/// a stale screen cannot talk Trio into a different dose.
///
/// Between the quote and the confirm, Trio checks the world has not moved: no insulin
/// given, no big change in BG, limits unchanged, the quote under three minutes old.
/// Then it re-runs Max Bolus, Max IOB and the recent-bolus check, saves the carbs, and
/// hands the dose to the pump.
///
/// Transport security -- the pairing, the per-request signature, the replay checks and
/// the lockout after repeated bad signatures -- follows Nathan Solis's Trio Companion
/// for Garmin (github.com/k9track/trio-garmin-companion, MIT). The quote and confirm
/// rules are the ones the AAPS Garmin plugin uses for the same watch app.
@MainActor final class GarminBolusHandler {
    typealias Reply = ([String: Any]) -> Void

    private static let lastAcceptedKey = "GarminBolus.lastAcceptedTimestamp"

    private var seenIDs: [String: Date] = [:]
    private var pending: GarminBolusProtocol.Quote?
    private var inFlight = false

    /// Watch boluses started in the last few minutes, in case the pump event is not
    /// stored yet when the next request is checked.
    private var recentWatchBoluses: [(date: Date, units: Decimal)] = []

    /// The last bolus the watch confirmed and how it ended, for the progress screen.
    private struct Outcome {
        enum State { case accepted, failed }
        let quoteID: String
        let requested: Decimal
        var state: State
        var error: String?
    }

    private var lastBolus: Outcome?
    /// The watch bolus being delivered now, so the progress screen has its total.
    private var activeUnits: Decimal = 0
    private var lastProgress: Decimal = 0
    /// Confirmed and handed over, but the pump has not reported yet. Counted as
    /// running, so a status asked for in that gap does not read as a finished bolus.
    private var awaitingStart = false
    private var awaitingSince = Date.distantPast
    private var stopPressed = false
    private var progressSubscription: AnyCancellable?

    nonisolated init() {}

    private var resolver: Resolver { TrioApp.resolver }
    private var apsManager: APSManager? { resolver.resolve(APSManager.self) }
    private var settingsManager: SettingsManager? { resolver.resolve(SettingsManager.self) }

    func handle(_ message: Any, kind: GarminBolusProtocol.Kind, reply: @escaping Reply) async {
        let rawID = (message as? [String: Any])?["id"] as? String ?? ""
        let ackType = kind.rawValue + "Ack"
        func answer(_ code: Int, _ fields: [String: Any] = [:]) {
            var out = fields
            out["t"] = ackType
            out["id"] = rawID
            out["code"] = code
            reply(out)
        }

        if kind == .pair {
            return handlePair(message, answer: answer)
        }

        guard let request = GarminBolusProtocol.Request(message: message) else {
            return answer(400, ["error": "Bad request"])
        }
        if let refusal = authorize(request) {
            debug(.watchManager, "Garmin bolus: \(kind.rawValue) refused, \(refusal.code)")
            return answer(refusal.code, ["error": refusal.message])
        }

        switch kind {
        case .quote:
            answer(200, await quote(request))
        case .confirm:
            answer(200, await confirm(request))
        case .carbs:
            answer(200, await logCarbs(request))
        case .bstatus:
            answer(200, status())
        case .cancel:
            answer(200, await cancel())
        case .pair:
            break
        }
    }

    // MARK: - Pairing

    private func handlePair(_ message: Any, answer: (Int, [String: Any]) -> Void) {
        func reject(_ msg: String) {
            debug(.watchManager, "Garmin pairing: rejected, \(msg)")
            answer(200, ["ok": false, "msg": msg])
        }
        guard GarminBolusSettings.isPairingOpen else { return reject("Tap Pair watch in Trio first") }
        guard let pin = GarminBolusSettings.pin else { return reject("Set a PIN in Trio first") }
        guard let request = GarminBolusProtocol.Request(message: message), request.kind == .pair else {
            return reject("Bad request")
        }
        let pinKey = SymmetricKey(data: Data(pin.utf8))
        guard GarminBolusProtocol.isSignatureValid(request.signature, for: request.signedString, key: pinKey) else {
            // Counted apart from bad request signatures, which a good request from
            // an already paired watch resets. Three wrong PINs close the window.
            GarminBolusSettings.pinFailures += 1
            if GarminBolusSettings.pinFailures >= GarminBolusSettings.maxPinFailures {
                GarminBolusSettings.closePairing()
                notify("Garmin pairing closed", "Three wrong PINs. Tap Pair Watch again if this was you.")
            }
            return reject("Wrong PIN")
        }
        guard isFresh(request.timestamp), seenIDs[request.id] == nil else {
            return reject("Check the watch time")
        }
        seenIDs[request.id] = Date()

        let key = GarminBolusSettings.makeWatchKey()
        GarminBolusSettings.closePairing()
        GarminBolusSettings.authFailures = 0
        GarminBolusSettings.pinFailures = 0
        debug(.watchManager, "Garmin pairing: watch paired")
        notify("Garmin watch paired", "The Bolus app on your watch can now ask Trio for a bolus.")
        answer(200, ["ok": true, "key": key, "msg": "Paired"])
    }

    // MARK: - Checks every request passes

    /// Nil when the request may be answered, otherwise the code and the reason.
    private func authorize(_ request: GarminBolusProtocol.Request) -> (code: Int, message: String)? {
        // Reading progress and stopping a bolus are allowed with watch bolus switched
        // off: a STOP must work whatever the toggle says.
        let readOnlyOrStop = request.kind == .bstatus || request.kind == .cancel
        if !readOnlyOrStop, !GarminBolusSettings.isEnabled {
            return (403, "Watch bolus is off in Trio")
        }
        guard let key = GarminBolusSettings.watchKey else {
            return (401, "Pair the watch in Trio")
        }
        guard GarminBolusProtocol.isSignatureValid(request.signature, for: request.signedString, key: key) else {
            recordAuthFailure()
            return (401, "Not authorized")
        }
        GarminBolusSettings.authFailures = 0

        guard isFresh(request.timestamp) else { return (408, "Check the watch time") }
        guard seenIDs[request.id] == nil else { return (409, "Duplicate request") }
        seenIDs[request.id] = Date()

        if request.changesState {
            let lastAccepted = UserDefaults.standard.integer(forKey: Self.lastAcceptedKey)
            guard request.timestamp > lastAccepted else { return (409, "Out-of-order request") }
            // Stored no later than now, so a fast watch clock cannot lock out the next one.
            let now = Int(Date().timeIntervalSince1970)
            UserDefaults.standard.set(min(request.timestamp, now), forKey: Self.lastAcceptedKey)
        }
        return nil
    }

    private func isFresh(_ timestamp: Int) -> Bool {
        let now = Date()
        seenIDs = seenIDs.filter { now.timeIntervalSince($0.value) < GarminBolusProtocol.maxClockSkew * 5 }
        let sentAt = Date(timeIntervalSince1970: TimeInterval(timestamp))
        return abs(now.timeIntervalSince(sentAt)) <= GarminBolusProtocol.maxClockSkew
    }

    /// A wrong PIN or signature. After a few in a row watch bolus switches itself off
    /// until it is turned back on in Trio, and the user is told.
    private func recordAuthFailure() {
        GarminBolusSettings.authFailures += 1
        let failures = GarminBolusSettings.authFailures
        debug(.watchManager, "Garmin bolus: bad signature, \(failures) in a row")
        guard failures >= GarminBolusSettings.maxAuthFailures else { return }
        GarminBolusSettings.setEnabled(false)
        GarminBolusSettings.closePairing()
        notify(
            "Garmin watch bolus turned off",
            "\(failures) requests with a wrong PIN or key. Turn it back on in Trio's Garmin settings if this was you."
        )
    }

    /// Why the pump cannot take a bolus right now, or nil when it can.
    ///
    /// A watch bolus counts from the moment it is handed over, not from when the
    /// pump says it is bolusing: in the second or two between, the pump's flag and
    /// its stored record both still read idle, and a quick second request would
    /// otherwise sail through every check.
    private func pumpRefusal() -> String? {
        guard let aps = apsManager else { return "Trio isn't ready" }
        guard let pump = aps.pumpManager else { return "No pump connected" }
        if aps.isSuspended { return "Pump suspended" }
        if pump.status.pumpStatus.bolusing || aps.bolusProgress.value != nil { return "Bolus in progress" }
        if awaitingStart, Date().timeIntervalSince(awaitingSince) <= 60 { return "Bolus in progress" }
        return nil
    }

    // MARK: - Quote

    private func quote(_ request: GarminBolusProtocol.Request) async -> [String: Any] {
        let id = GarminBolusProtocol.newQuoteID()
        func refused(_ msg: String) -> [String: Any] {
            pending = nil
            return ["q": id, "insulin": 0.0, "carbs": 0, "requested": 0.0, "trimmed": false, "refused": msg]
        }

        if let refusal = pumpRefusal() { return refused(refusal) }
        guard request.centiUnits > 0 || request.carbs > 0 else { return refused("Nothing to deliver") }
        guard let aps = apsManager, let settings = settingsManager else { return refused("Trio isn't ready") }

        let carbLimit = min(settings.settings.maxCarbs, GarminBolusSettings.maxCarbs)
        let allowedCarbs = min(request.carbs, NSDecimalNumber(decimal: carbLimit).intValue)

        // Snapshot before pricing, so anything that lands after is caught at confirm.
        let reading = await latestReading()
        let newestManual = await newestBolusDate(manualOnly: true)
        let newestAny = await newestBolusDate(manualOnly: false)

        let fromWizard = request.centiUnits == 0 && allowedCarbs > 0
        let requested: Decimal
        var allowed: Decimal
        if fromWizard {
            // Trio's own calculator, the one behind the phone's bolus screen, so carb
            // ratio, ISF, target, IOB, COB and the user's fraction arrive exactly as
            // they would there. Reimplementing that arithmetic for a watch is how two
            // answers start to differ.
            let result = await calculate(carbs: allowedCarbs, lastLoopDate: aps.lastLoopDate)
            requested = result.factoredInsulin
            allowed = result.insulinCalculated
        } else {
            requested = request.units
            allowed = request.units
        }

        allowed = min(allowed, GarminBolusSettings.maxBolus)
        allowed = allowed > 0 ? aps.roundBolus(amount: allowed) : 0

        if allowed > 0 {
            if let reason = await safetyRefusal(units: allowed, since: nil) { return refused(reason) }
        }

        pending = GarminBolusProtocol.Quote(
            id: id,
            createdAt: Date(),
            fromWizard: fromWizard,
            insulin: allowed,
            carbs: allowedCarbs,
            reading: reading,
            newestManualBolusAt: newestManual,
            newestAnyBolusAt: newestAny
        )
        debug(.watchManager, "Garmin bolus: quoted \(allowed) U for \(allowedCarbs) g, wizard \(fromWizard)")
        return [
            "q": id,
            "insulin": NSDecimalNumber(decimal: allowed).doubleValue,
            "carbs": allowedCarbs,
            "requested": NSDecimalNumber(decimal: requested).doubleValue,
            "trimmed": allowed < requested
        ]
    }

    private func calculate(carbs: Int, lastLoopDate: Date) async -> CalculationResult {
        var minPredBG: Decimal = 54
        if let storage = resolver.resolve(DeterminationStorage.self) {
            let context = CoreDataStack.shared.newTaskContext()
            if let ids = try? await storage.fetchLastDeterminationObjectID(
                predicate: NSPredicate.predicateFor30MinAgoForDetermination
            ),
                let objects: [OrefDetermination] = try? await CoreDataStack.shared.getNSManagedObject(
                    with: ids,
                    context: context
                )
            {
                minPredBG = await context.perform { objects.first?.minPredBGFromReason ?? 54 }
            }
        }
        guard let calculator = resolver.resolve(BolusCalculationManager.self) else {
            return CalculationResult(
                insulinCalculated: 0, factoredInsulin: 0, wholeCalc: 0, iobInsulinReduction: 0,
                superBolusInsulin: 0, targetDifference: 0, targetDifferenceInsulin: 0,
                fifteenMinutesInsulin: 0, wholeCob: 0, wholeCobInsulin: 0
            )
        }
        return await calculator.handleBolusCalculation(
            carbs: Decimal(carbs),
            useFattyMealCorrection: false,
            useSuperBolus: false,
            lastLoopDate: lastLoopDate,
            minPredBG: minPredBG,
            simulatedCOB: nil,
            isBackdated: false
        )
    }

    /// Max Bolus, Max IOB and the recent-bolus check, the same validator Trio runs on
    /// every bolus that does not come from its own bolus screen.
    private func safetyRefusal(units: Decimal, since: Date?) async -> String? {
        let window = TimeInterval(BolusSafetyEvaluator.recentBolusWindowMinutes * 60)
        recentWatchBoluses.removeAll { Date().timeIntervalSince($0.date) > window }
        let recentWatch = recentWatchBoluses.reduce(Decimal(0)) { $0 + $1.units }
        if recentWatch >= units * BolusSafetyEvaluator.recentBolusThreshold {
            return "A bolus was just given"
        }
        guard let validator = resolver.resolve(BolusSafetyValidator.self) else { return "Trio isn't ready" }
        let usualStart = Date().addingTimeInterval(-window)
        do {
            switch try await validator.validate(bolusAmount: units, lookbackStart: min(since ?? usualStart, usualStart)) {
            case .allowed:
                return nil
            case let .rejected(reason):
                return reason.garminMessage
            }
        } catch {
            return "Couldn't check recent boluses"
        }
    }

    // MARK: - Confirm

    private func confirm(_ request: GarminBolusProtocol.Request) async -> [String: Any] {
        func no(_ msg: String) -> [String: Any] {
            debug(.watchManager, "Garmin bolus: confirm refused, \(msg)")
            return ["ok": false, "error": msg]
        }
        guard let quote = pending else { return no("Nothing is waiting to be confirmed") }
        // The id has to match: a confirm delayed on the wrist could otherwise approve
        // a different figure than the one that was read.
        guard quote.id == request.quoteID else { return no("This confirmation does not match the request") }
        // Spent from here whatever the answer. A refused confirm is never retried
        // against the same figure; the watch asks for a new one.
        pending = nil

        guard !inFlight else { return no("Another watch request is in progress") }
        inFlight = true
        defer { inFlight = false }

        if let refusal = pumpRefusal() { return no(refusal) }
        let world = await GarminBolusProtocol.World(
            now: Date(),
            reading: latestReading(),
            newestManualBolusAt: newestBolusDate(manualOnly: true),
            newestAnyBolusAt: newestBolusDate(manualOnly: false)
        )
        if let stale = GarminBolusProtocol.staleness(of: quote, in: world) { return no(stale) }

        // Limits can change in the gap too. A figure the user did not approve is
        // refused rather than quietly cut.
        guard let aps = apsManager, let settings = settingsManager else { return no("Trio isn't ready") }
        if quote.insulin > 0 {
            let stillAllowed = aps.roundBolus(amount: min(quote.insulin, GarminBolusSettings.maxBolus))
            if stillAllowed < quote.insulin { return no("Limits changed, ask again") }
            if let reason = await safetyRefusal(units: quote.insulin, since: quote.createdAt) { return no(reason) }
        }
        if Decimal(quote.carbs) > min(settings.settings.maxCarbs, GarminBolusSettings.maxCarbs) {
            return no("Limits changed, ask again")
        }

        if quote.carbs > 0 {
            do {
                try await saveCarbs(quote.carbs)
            } catch {
                debug(.watchManager, "Garmin bolus: saving carbs failed, \(error)")
                return no("Couldn't save carbs, nothing given")
            }
        }
        guard quote.insulin > 0 else {
            notify("Carbs from Garmin watch", "\(quote.carbs) g logged.")
            return ["ok": true]
        }

        // Counted as given now, before the pump is asked, so the recent-bolus check
        // sees it however late the pump's record lands. Taken back if it fails.
        let handedAt = Date()
        recentWatchBoluses.append((handedAt, quote.insulin))
        lastBolus = Outcome(quoteID: quote.id, requested: quote.insulin, state: .accepted)
        activeUnits = quote.insulin
        lastProgress = 0
        stopPressed = false
        awaitingStart = true
        awaitingSince = Date()
        watchProgress(aps)

        let units = quote.insulin
        let carbs = quote.carbs
        let quoteID = quote.id
        // Answered as soon as the dose is handed over, the same as AAPS does. What the
        // pump made of it, the watch learns from the status it polls next.
        Task { @MainActor [weak self] in
            await aps.enactBolus(amount: NSDecimalNumber(decimal: units).doubleValue, isSMB: false) { success, msg in
                Task { @MainActor in
                    guard let self, self.lastBolus?.quoteID == quoteID else { return }
                    self.awaitingStart = false
                    debug(.watchManager, "Garmin bolus: \(quoteID) \(success ? "started" : "failed")")
                    if success {
                        self.notify(
                            "Bolus from Garmin watch",
                            "\(units) U started" + (carbs > 0 ? " with \(carbs) g carbs." : ".")
                        )
                    } else {
                        self.recentWatchBoluses.removeAll { $0.date == handedAt }
                        self.lastBolus?.state = .failed
                        self.lastBolus?.error = msg
                        self.activeUnits = 0
                        self.notify("Garmin watch bolus failed", msg)
                    }
                }
            }
        }
        return ["ok": true]
    }

    // MARK: - Carbs on their own

    private func logCarbs(_ request: GarminBolusProtocol.Request) async -> [String: Any] {
        // Negative carbs lower COB and hold insulin back; zero is nothing. Only real
        // food is recorded.
        guard request.carbs > 0 else { return ["carbs": 0] }
        let limit = min(settingsManager?.settings.maxCarbs ?? 0, GarminBolusSettings.maxCarbs)
        let grams = min(request.carbs, NSDecimalNumber(decimal: limit).intValue)
        guard grams > 0 else { return ["carbs": 0] }
        do {
            try await saveCarbs(grams)
        } catch {
            debug(.watchManager, "Garmin bolus: saving carbs failed, \(error)")
            return ["error": "Couldn't save carbs"]
        }
        notify("Carbs from Garmin watch", "\(grams) g logged.")
        return ["carbs": grams]
    }

    // MARK: - Progress and stop

    /// Keeps the last progress figure, so a bolus that is stopped part way can still
    /// say roughly how much went in.
    private func watchProgress(_ aps: APSManager) {
        guard progressSubscription == nil else { return }
        progressSubscription = aps.bolusProgress
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in
                guard let self, let value else { return }
                self.lastProgress = value
                self.awaitingStart = false
            }
    }

    private func status() -> [String: Any] {
        let progress = apsManager?.bolusProgress.value
        // A pump that never reports would leave this set; after a minute the pump's
        // own state is the only word.
        if awaitingStart, Date().timeIntervalSince(awaitingSince) > 60 { awaitingStart = false }
        let active = progress != nil || awaitingStart
        let fraction = progress ?? lastProgress
        let goal = active ? activeUnits : 0
        var out: [String: Any] = [
            "ok": true,
            "active": active,
            "insulin": NSDecimalNumber(decimal: goal).doubleValue,
            "delivered": NSDecimalNumber(decimal: goal * fraction).doubleValue,
            "percent": NSDecimalNumber(decimal: fraction * 100).intValue,
            "ended": !active,
            "stopped": stopPressed
        ]
        if let last = lastBolus {
            out["lastBolusId"] = last.quoteID
            out["lastBolusRequested"] = NSDecimalNumber(decimal: last.requested).doubleValue
            switch last.state {
            case .failed:
                out["lastBolusResult"] = "failed"
                if let error = last.error, !error.isEmpty { out["lastBolusError"] = error }
            case .accepted where active:
                out["lastBolusResult"] = "pending"
            case .accepted:
                // Finished. Trio's pump drivers report progress, not the units that left,
                // so a stopped bolus is estimated from the last progress seen.
                let delivered = stopPressed ? last.requested * lastProgress : last.requested
                out["lastBolusResult"] = "delivered"
                out["lastBolusDelivered"] = NSDecimalNumber(decimal: delivered).doubleValue
            }
        }
        if !active { activeUnits = 0 }
        return out
    }

    /// The STOP button. Answers once the stop is handed to the pump; what actually
    /// went in, the watch learns from the next status.
    private func cancel() async -> [String: Any] {
        stopPressed = true
        if let aps = apsManager {
            // The stop always goes to the pump. Only the notification waits for a
            // bolus to have been running, so a STOP pressed on nothing says nothing.
            let wasRunning = aps.bolusProgress.value != nil || awaitingStart
            await aps.cancelBolus { success, _ in
                debug(.watchManager, "Garmin bolus: stop \(success ? "accepted" : "failed")")
            }
            awaitingStart = false
            if wasRunning { notify("Bolus stopped from Garmin watch", "Check Trio for the amount delivered.") }
        }
        return status()
    }

    // MARK: - Reading Trio's records

    private func latestReading() async -> GarminBolusProtocol.Reading? {
        let context = CoreDataStack.shared.newTaskContext()
        guard let results = try? await CoreDataStack.shared.fetchEntitiesAsync(
            ofType: GlucoseStored.self,
            onContext: context,
            predicate: NSPredicate.glucose,
            key: "date",
            ascending: false,
            fetchLimit: 1
        ) else { return nil }
        return await context.perform {
            guard let reading = (results as? [GlucoseStored])?.first, let date = reading.date else { return nil }
            return GarminBolusProtocol.Reading(mgdl: Int(reading.glucose), date: date)
        }
    }

    /// When the newest bolus started. Manual means anything but an SMB, which is what
    /// "insulin given since the quote" has to catch for a dose the user named.
    private func newestBolusDate(manualOnly: Bool) async -> Date? {
        let context = CoreDataStack.shared.newTaskContext()
        let type = PumpEventStored.EventType.bolus.rawValue
        let predicate = manualOnly
            ? NSPredicate(format: "type == %@ AND bolus.isSMB == NO", type)
            : NSPredicate(format: "type == %@", type)
        guard let results = try? await CoreDataStack.shared.fetchEntitiesAsync(
            ofType: PumpEventStored.self,
            onContext: context,
            predicate: predicate,
            key: "timestamp",
            ascending: false,
            fetchLimit: 1
        ) else { return nil }
        return await context.perform { (results as? [PumpEventStored])?.first?.timestamp }
    }

    private func saveCarbs(_ grams: Int) async throws {
        let context = CoreDataStack.shared.newTaskContext()
        try await context.perform {
            let entry = CarbEntryStored(context: context)
            entry.id = UUID()
            entry.carbs = Double(grams)
            entry.date = Date()
            entry.note = "Via Garmin"
            // Shown in the main chart like any other carbs, not folded into FPU.
            entry.isFPU = false
            entry.isUploadedToNS = false
            entry.isUploadedToHealth = false
            entry.isUploadedToTidepool = false
            try context.save()
        }
    }

    nonisolated func notify(_ title: String, _ body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "GarminBolus.\(UUID().uuidString)", content: content, trigger: nil)
        )
    }
}

private extension BolusSafetyRejection {
    /// Short enough for a round watch screen.
    var garminMessage: String {
        switch self {
        case let .exceedsMaxBolus(maxBolus):
            return "Over max bolus (\(maxBolus) U)"
        case .iobUnavailable:
            return "IOB unavailable"
        case let .exceedsMaxIOB(currentIOB, maxIOB):
            return "Over max IOB (\(maxIOB) U, now \(currentIOB.rounded(toPlaces: 2)) U)"
        case .recentBolusWithinWindow:
            return "A bolus was just given"
        }
    }
}
