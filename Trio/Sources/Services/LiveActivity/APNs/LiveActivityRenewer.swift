import ActivityKit
import Foundation

/// Keeps the Live Activity alive past iOS's 8-hour limit without opening the app.
///
/// Shortly before the limit, while Trio runs in the background, it sends a
/// push-to-start push to its own push-to-start token through APNs (signed on the
/// phone, no server). iOS starts a fresh activity, LiveActivityManager adopts it
/// and ends the old one. If APNs refuses or the token is missing, the old
/// behaviour stays: the activity is replaced the next time the app is opened.
final class LiveActivityRenewer {
    private enum Keys {
        static let pushToStartToken = "liveActivity.apns.pushToStartToken"
        static let renewalState = "liveActivity.apns.renewalState"
    }

    private let client: LiveActivityAPNsClient
    private let defaults: UserDefaults

    @MainActor private(set) var pushToStartToken: String? {
        didSet { defaults.set(pushToStartToken, forKey: Keys.pushToStartToken) }
    }

    /// Push tokens of running activities, by activity id. Kept for update pushes.
    @MainActor private(set) var activityPushTokens: [String: String] = [:]

    @MainActor private var state: LiveActivityRenewalPolicy.State {
        didSet {
            if let data = try? JSONEncoder().encode(state) {
                defaults.set(data, forKey: Keys.renewalState)
            }
        }
    }

    @MainActor private var sendInFlight = false
    @MainActor private var observationTasks: [Task<Void, Never>] = []

    /// `nil` when the build carries no APNs key.
    static func makeIfConfigured() -> LiveActivityRenewer? {
        guard let signer = LiveActivityAPNsCredentials.signer else { return nil }
        return LiveActivityRenewer(client: LiveActivityAPNsClient(signer: signer))
    }

    init(client: LiveActivityAPNsClient, defaults: UserDefaults = .standard) {
        self.client = client
        self.defaults = defaults
        pushToStartToken = defaults.string(forKey: Keys.pushToStartToken)
        state = defaults.data(forKey: Keys.renewalState)
            .flatMap { try? JSONDecoder().decode(LiveActivityRenewalPolicy.State.self, from: $0) }
            ?? LiveActivityRenewalPolicy.State()
    }

    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    /// Watches for the push-to-start token and for activities iOS starts from a push.
    @MainActor func startObserving(onNewActivity: @escaping @MainActor(Activity<LiveActivityAttributes>) -> Void) {
        observationTasks.forEach { $0.cancel() }
        observationTasks = [
            Task { [weak self] in
                for await data in Activity<LiveActivityAttributes>.pushToStartTokenUpdates {
                    let token = Self.hex(data)
                    await MainActor.run {
                        guard let self, self.pushToStartToken != token else { return }
                        self.pushToStartToken = token
                        debug(.default, "[LiveActivityRenewer] push-to-start token updated …\(token.suffix(8))")
                    }
                }
            },
            Task {
                for await activity in Activity<LiveActivityAttributes>.activityUpdates {
                    await onNewActivity(activity)
                }
            }
        ]
    }

    /// Records an activity's own push token as iOS issues it.
    @MainActor func observePushToken(of activity: Activity<LiveActivityAttributes>) {
        let id = activity.id
        observationTasks.append(Task { [weak self] in
            for await data in activity.pushTokenUpdates {
                let token = Self.hex(data)
                await MainActor.run {
                    self?.activityPushTokens[id] = token
                }
            }
        })
    }

    /// The pushed activity has appeared and replaced the old one.
    @MainActor func didAdoptRenewedActivity() {
        state = LiveActivityRenewalPolicy.adopted()
    }

    @MainActor func forgetActivity(id: String) {
        activityPushTokens[id] = nil
    }

    /// Sends a push-to-start when the current activity is near the 8-hour limit
    /// and the app is in the background. Returns true when a push went out.
    @MainActor @discardableResult func renewIfDue(
        activity: Activity<LiveActivityAttributes>,
        content: LiveActivityAttributes.ContentState,
        appIsActive: Bool,
        now: Date = Date()
    ) async -> Bool {
        guard !sendInFlight else { return false }
        let (decision, newState) = LiveActivityRenewalPolicy.decide(
            activityStart: activity.attributes.startDate,
            now: now,
            appIsActive: appIsActive,
            hasPushToStartToken: pushToStartToken != nil,
            state: state
        )
        if newState != state { state = newState }

        switch decision {
        case .foreground,
             .notDue,
             .waitingForAdoption:
            return false
        case let .backingOff(until):
            debug(.default, "[LiveActivityRenewer] renewal due, backing off until \(until)")
            return false
        case .noToken:
            debug(.default, "[LiveActivityRenewer] renewal due, no push-to-start token yet")
            return false
        case .pushToStart:
            break
        }

        guard let token = pushToStartToken else { return false }
        sendInFlight = true
        defer { sendInFlight = false }

        debug(.default, "[LiveActivityRenewer] renewing activity \(activity.id) via push-to-start")
        let result = await client.sendStart(
            pushToStartToken: token,
            state: content,
            attributes: LiveActivityAttributes(startDate: now),
            staleDate: min(content.date ?? now, now).addingTimeInterval(360),
            now: now
        )
        debug(.default, "[LiveActivityRenewer] push-to-start result: \(result)")

        let outcome: LiveActivityRenewalPolicy.Outcome
        switch result {
        case .delivered:
            outcome = .sent
        case .badDeviceToken:
            outcome = .tokenInvalid
            if pushToStartToken == token { pushToStartToken = nil }
        case .rateLimited:
            outcome = .rateLimited
        case .failed,
             .providerTokenRejected,
             .serverError:
            outcome = .failed
        }
        state = LiveActivityRenewalPolicy.record(outcome, state: state, now: now)
        return outcome == .sent
    }

    /// Updates a running activity through APNs at routine priority (not budgeted).
    /// Trio updates its activity locally while it runs, so this is kept for cases
    /// where a local update is not possible.
    @MainActor func sendUpdate(
        activityID: String,
        content: LiveActivityAttributes.ContentState,
        now: Date = Date()
    ) async -> APNsPushResult? {
        guard let token = activityPushTokens[activityID] else { return nil }
        let result = await client.sendUpdate(
            activityToken: token,
            state: content,
            staleDate: min(content.date ?? now, now).addingTimeInterval(360),
            now: now
        )
        if case .badDeviceToken = result {
            activityPushTokens[activityID] = nil
        }
        return result
    }
}
