import Foundation
import WatchConnectivity
import WidgetKit

// MARK: - Send Data to Phone

extension WatchState {
    /// Sends a bolus insulin request to the paired iPhone
    /// - Parameters:
    ///   - amount: The insulin amount to be delivered
    func sendBolusRequest(_ amount: Decimal) {
        guard let session = session, session.isReachable else {
            Task {
                await WatchLogger.shared.log("⌚️ Bolus request aborted: session unreachable")
            }
            return
        }

        Task {
            await WatchLogger.shared.log("⌚️ Sending bolus request: \(amount)U")
        }

        let message: [String: Any] = [
            WatchMessageKeys.bolus: amount
        ]

        session.sendMessage(message, replyHandler: nil) { error in
            Task {
                await WatchLogger.shared.log("Error sending bolus request: \(error)")
            }
        }

        // Display pending communication animation
        showCommsAnimation = true
        Task {
            await WatchLogger.shared.log("⌚️ showCommsAnimation = true")
        }
    }

    /// Sends a carbohydrate entry request to the paired iPhone
    /// - Parameters:
    ///   - amount: The amount of carbs in grams
    ///   - date: The timestamp for the carb entry (defaults to current time)
    func sendCarbsRequest(_ amount: Int, _ date: Date = Date()) {
        guard let session = session, session.isReachable else {
            Task {
                await WatchLogger.shared.log("⌚️ Carbs request aborted: session unreachable")
            }
            return
        }

        Task {
            await WatchLogger.shared.log("⌚️ Sending carbs request: \(amount)g at \(date)")
        }

        let message: [String: Any] = [
            WatchMessageKeys.carbs: amount,
            WatchMessageKeys.date: date.timeIntervalSince1970
        ]

        session.sendMessage(message, replyHandler: nil) { error in
            Task {
                await WatchLogger.shared.log("Error sending carbs request: \(error)")
                await WatchLogger.shared.log("⌚️ Saving logs to disk as fallback!")
                await WatchLogger.shared.persistLogsLocally()
            }
        }

        // Display pending communication animation
        showCommsAnimation = true
        Task {
            await WatchLogger.shared.log("⌚️ showCommsAnimation = true")
        }
    }

    /// Sends a request to cancel the current override preset to the paired iPhone
    func sendCancelOverrideRequest() {
        guard let session = session, session.isReachable else {
            Task {
                await WatchLogger.shared.log("⌚️ Cancel override request aborted: session unreachable")
            }
            return
        }

        Task {
            await WatchLogger.shared.log("⌚️ Sending cancel override request")
        }

        let message: [String: Any] = [
            WatchMessageKeys.cancelOverride: true
        ]

        session.sendMessage(message, replyHandler: nil) { error in
            Task {
                await WatchLogger.shared.log("⌚️ Error sending cancel override request: \(error)")
                await WatchLogger.shared.log("⌚️ Saving logs to disk as fallback!")
                await WatchLogger.shared.persistLogsLocally()
            }
        }

        // Display pending communication animation
        showCommsAnimation = true
        Task {
            await WatchLogger.shared.log("⌚️ showCommsAnimation = true")
        }
    }

    /// Sends a request to activate an override preset to the paired iPhone
    /// - Parameter presetName: The name of the override preset to activate
    func sendActivateOverrideRequest(presetName: String) {
        guard let session = session, session.isReachable else {
            Task {
                await WatchLogger.shared.log("⌚️ Activate override request aborted: session unreachable")
            }
            return
        }

        Task {
            await WatchLogger.shared.log("⌚️ Sending activate override request for preset: \(presetName)")
        }

        let message: [String: Any] = [
            WatchMessageKeys.activateOverride: presetName
        ]

        session.sendMessage(message, replyHandler: nil) { error in
            Task {
                await WatchLogger.shared.log("⌚️ Error sending activate override request: \(error)")
                await WatchLogger.shared.log("⌚️ Saving logs to disk as fallback!")
                await WatchLogger.shared.persistLogsLocally()
            }
        }

        // Display pending communication animation
        showCommsAnimation = true
        Task {
            await WatchLogger.shared.log("⌚️ showCommsAnimation = true")
        }
    }

    /// Sends a request to cancel the current temporary target to the paired iPhone
    func sendCancelTempTargetRequest() {
        guard let session = session, session.isReachable else {
            Task {
                await WatchLogger.shared.log("⌚️ Cancel temp target request aborted: session unreachable")
            }
            return
        }

        Task {
            await WatchLogger.shared.log("⌚️ Sending cancel temp target request")
        }

        let message: [String: Any] = [
            WatchMessageKeys.cancelTempTarget: true
        ]

        session.sendMessage(message, replyHandler: nil) { error in
            Task {
                await WatchLogger.shared.log("⌚️ Error sending cancel temp target request: \(error)")
                await WatchLogger.shared.log("⌚️ Saving logs to disk as fallback!")
                await WatchLogger.shared.persistLogsLocally()
            }
        }

        // Display pending communication animation
        showCommsAnimation = true
        Task {
            await WatchLogger.shared.log("⌚️ showCommsAnimation = true")
        }
    }

    /// Sends a request to activate a temporary target preset to the paired iPhone
    /// - Parameter presetName: The name of the temporary target preset to activate
    func sendActivateTempTargetRequest(presetName: String) {
        guard let session = session, session.isReachable else {
            Task {
                await WatchLogger.shared.log("⌚️ Activate temp target request aborted: session unreachable")
            }
            return
        }

        Task {
            await WatchLogger.shared.log("⌚️ Sending activate temp target request for preset: \(presetName)")
        }

        let message: [String: Any] = [
            WatchMessageKeys.activateTempTarget: presetName
        ]

        session.sendMessage(message, replyHandler: nil) { error in
            Task {
                await WatchLogger.shared.log("⌚️ Error sending activate temp target request: \(error)")
                await WatchLogger.shared.log("⌚️ Saving logs to disk as fallback!")
                await WatchLogger.shared.persistLogsLocally()
            }
        }

        // Display pending communication animation
        showCommsAnimation = true
        Task {
            await WatchLogger.shared.log("⌚️ showCommsAnimation = true")
        }
    }

    /// Sends a request to calculate a bolus recommendation based on the current carbs amount
    func requestBolusRecommendation() {
        guard let session = session, session.isReachable else {
            Task {
                await WatchLogger.shared.log("⌚️ Bolus recommendation request aborted: session unreachable")
            }
            return
        }

        Task {
            await WatchLogger.shared.log("⌚️ Requesting bolus recommendation for carbs: \(carbsAmount)")
        }

        let message: [String: Any] = [
            WatchMessageKeys.requestBolusRecommendation: true,
            WatchMessageKeys.carbs: carbsAmount
        ]

        session.sendMessage(message, replyHandler: nil) { error in
            Task {
                await WatchLogger.shared.log("Error requesting bolus recommendation: \(error)")
                await WatchLogger.shared.log("⌚️ Saving logs to disk as fallback!")
                await WatchLogger.shared.persistLogsLocally()
            }
        }
    }

    func requestWatchStateUpdate() {
        guard let session = session else {
            Task {
                await WatchLogger.shared.log("⌚️ No session available for state update")
            }
            return
        }

        guard session.activationState == .activated else {
            Task {
                await WatchLogger.shared.log("⌚️ Session not activated. Activating...")
            }
            session.activate()
            return
        }

        if session.isReachable {
            Task {
                await WatchLogger.shared.log("⌚️ Requesting WatchState update from iPhone")
            }

            let message = [WatchMessageKeys.requestWatchUpdate: WatchMessageKeys.watchState]

            session.sendMessage(message, replyHandler: nil) { error in
                Task {
                    await WatchLogger.shared.log("⌚️ Error requesting WatchState update: \(error)")
                    await WatchLogger.shared.log("⌚️ Saving logs to disk as fallback!")
                    await WatchLogger.shared.persistLogsLocally()
                }
            }
        } else {
            Task {
                await WatchLogger.shared.log("⌚️ Phone not reachable for WatchState update")
            }
        }
    }
}

// MARK: - Nightscout fallback fetch

/// Lets the watch pull the latest glucose straight from Nightscout when the phone
/// link is down (dormant app, wedged WCSession, phone away). Config arrives from
/// the phone with each complication update (secret pre-hashed — never raw).
/// Read-only; only ever writes newer data than what's already stored.
enum NightscoutFetcher {
    struct Config: Codable {
        let url: String
        let secretSHA1: String
        let units: String
        let low: Double
        let high: Double
    }

    private static let configKey = "nsFetch.config.v1"

    static func saveConfigIfPresent(from userInfo: [String: Any]) {
        guard let url = userInfo[WatchMessageKeys.nsURL] as? String, !url.isEmpty else { return }
        let config = Config(
            url: url,
            secretSHA1: userInfo[WatchMessageKeys.nsSecretSHA1] as? String ?? "",
            units: userInfo[WatchMessageKeys.units] as? String ?? "mg/dL",
            low: userInfo[WatchMessageKeys.lowThreshold] as? Double ?? 70,
            high: userInfo[WatchMessageKeys.highThreshold] as? Double ?? 180
        )
        if let data = try? JSONEncoder().encode(config) {
            // App Group so the complication's own timeline fetch can read it too.
            (sharedUserDefaults ?? UserDefaults.standard).set(data, forKey: configKey)
            sharedUserDefaults?.synchronize()
        }
    }

    static func loadConfig() -> Config? {
        guard let data = (sharedUserDefaults ?? UserDefaults.standard).data(forKey: configKey),
              let config = try? JSONDecoder().decode(Config.self, from: data) else { return nil }
        return config
    }

    /// Fetches the two most recent readings and stores them for the complication
    /// if they're newer than what we already have. Returns true when new data landed.
    @discardableResult static func fetchAndStore() async -> Bool {
        guard let config = loadConfig(),
              var components = URLComponents(string: config.url.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        else { return false }
        components.path += "/api/v1/entries/sgv.json"
        components.queryItems = [URLQueryItem(name: "count", value: "2")]
        guard let url = components.url else { return false }

        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        if !config.secretSHA1.isEmpty {
            request.addValue(config.secretSHA1, forHTTPHeaderField: "api-secret")
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200 ... 299).contains(http.statusCode),
                  let entries = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                  let newest = entries.first,
                  let sgv = newest["sgv"] as? Int
            else { return false }

            let dateMs = (newest["date"] as? Double) ?? 0
            let readingDate = Date(timeIntervalSince1970: dateMs / 1000)

            // Only overwrite when strictly newer than the stored reading.
            if let existing = GlucoseComplicationData.load(),
               let existingDate = existing.glucoseDate,
               readingDate.timeIntervalSince(existingDate) < 30
            {
                return false
            }

            let isMmol = config.units != "mg/dL"
            func display(_ mgdl: Int) -> String {
                isMmol ? String(format: "%.1f", Double(mgdl) / 18.0182) : "\(mgdl)"
            }
            let displayValue = isMmol ? Double(sgv) / 18.0182 : Double(sgv)

            var deltaString = "--"
            if entries.count > 1, let prev = entries[1]["sgv"] as? Int {
                let d = sgv - prev
                deltaString = isMmol
                    ? String(format: "%+.1f", Double(d) / 18.0182)
                    : String(format: "%+d", d)
            }

            let trend: String
            switch newest["direction"] as? String {
            case "DoubleUp",
                 "TripleUp": trend = "↑↑"
            case "SingleUp": trend = "↑"
            case "FortyFiveUp": trend = "↗"
            case "Flat": trend = "→"
            case "FortyFiveDown": trend = "↘"
            case "SingleDown": trend = "↓"
            case "DoubleDown",
                 "TripleDown": trend = "↓↓"
            default: trend = "→"
            }

            // IOB/COB/eventual come from the loop, not Nightscout entries — omit
            // rather than show hours-old values as current.
            let complicationData = GlucoseComplicationData(
                glucose: display(sgv),
                trend: trend,
                delta: deltaString,
                iob: nil,
                cob: nil,
                glucoseDate: readingDate,
                lastLoopDate: nil,
                isUrgent: displayValue <= config.low || displayValue >= config.high
            )
            complicationData.save()

            Task { await WatchLogger.shared.log("🌐 NS fallback fetch stored \(sgv) @ \(readingDate)") }

            await MainActor.run {
                WidgetCenter.shared.reloadAllTimelines()
            }
            return true
        } catch {
            Task { await WatchLogger.shared.log("🌐 NS fallback fetch failed: \(error.localizedDescription)") }
            return false
        }
    }
}
