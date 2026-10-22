import Foundation

/// When to replace the Live Activity before iOS ends it at 8 hours, and how to
/// back off when APNs refuses. Pure, so the timing can be tested.
///
/// The app renews in the background with a push-to-start push to itself. In the
/// foreground the existing hourly local restart already covers it. If renewal
/// keeps failing the app falls back to that foreground restart, as before.
enum LiveActivityRenewalPolicy {
    /// iOS ends a Live Activity 8 hours after it starts. Renew with 30 minutes to spare.
    static let renewAfter: TimeInterval = 7.5 * 3600
    /// How long to wait for the pushed activity to appear before counting the send as failed.
    static let adoptionTimeout: TimeInterval = 10 * 60
    static let baseBackoff: TimeInterval = 5 * 60
    static let maxBackoff: TimeInterval = 60 * 60

    struct State: Codable, Equatable {
        /// When a push-to-start was accepted by APNs and the new activity has not shown up yet.
        var pendingSince: Date?
        /// No push-to-start before this time.
        var backoffUntil: Date?
        /// The current backoff step, doubled on each failure.
        var backoff: TimeInterval = 0
        var consecutiveFailures: Int = 0
    }

    enum Decision: Equatable {
        case notDue
        /// The app is in the foreground. The local restart handles it.
        case foreground
        case noToken
        case waitingForAdoption
        case backingOff(until: Date)
        case pushToStart
    }

    enum Outcome: Equatable {
        case sent
        case rateLimited
        case tokenInvalid
        case failed
    }

    static func isDue(activityStart: Date, now: Date) -> Bool {
        now.timeIntervalSince(activityStart) >= renewAfter
    }

    /// The decision, plus the state with an expired adoption wait turned into a failure.
    static func decide(
        activityStart: Date,
        now: Date,
        appIsActive: Bool,
        hasPushToStartToken: Bool,
        state: State
    ) -> (Decision, State) {
        guard isDue(activityStart: activityStart, now: now) else { return (.notDue, state) }
        if appIsActive { return (.foreground, state) }

        var state = state
        if let pendingSince = state.pendingSince {
            if now.timeIntervalSince(pendingSince) < adoptionTimeout {
                return (.waitingForAdoption, state)
            }
            // APNs took it but no activity appeared. Treat as a failure.
            state = record(.failed, state: state, now: now)
        }
        if let until = state.backoffUntil, now < until {
            return (.backingOff(until: until), state)
        }
        guard hasPushToStartToken else { return (.noToken, state) }
        return (.pushToStart, state)
    }

    static func record(_ outcome: Outcome, state: State, now: Date) -> State {
        var state = state
        switch outcome {
        case .sent:
            state.pendingSince = now
            state.backoffUntil = nil
        case .tokenInvalid:
            // Wait for iOS to issue a new push-to-start token. No point holding off.
            state.pendingSince = nil
            state.consecutiveFailures += 1
            state.backoffUntil = nil
        case .failed,
             .rateLimited:
            state.pendingSince = nil
            state.consecutiveFailures += 1
            state.backoff = min(maxBackoff, max(baseBackoff, state.backoff * 2))
            state.backoffUntil = now.addingTimeInterval(state.backoff)
        }
        return state
    }

    /// The new activity appeared. Clean slate.
    static func adopted() -> State {
        State()
    }
}
