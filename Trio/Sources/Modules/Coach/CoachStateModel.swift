import Foundation
import Observation
import SwiftUI

/// Namespace for the Trio Coach module (the personal diabetes settings coach).
enum Coach {
    /// The non-dismissible advisory line shown above every coach surface.
    static let advisoryBanner = "Suggestions only — you decide and apply changes yourself."
}

extension Coach {
    /// Thin presentation state for the coach surface. The conversation and the
    /// notes inbox both live in the long-lived `CoachInbox` singleton (mirroring
    /// how `MealChatSession.shared` backs the Meal Advisor), so the view binds to
    /// that directly. This model just owns view-local toggles and the
    /// refresh-on-appear trigger.
    ///
    /// ADVISORY ONLY: no apply/dose action exists on this surface.
    @Observable final class StateModel {
        @ObservationIgnored let inbox = CoachInbox.shared

        /// Which tab of the surface is showing: the chat or the notes inbox.
        var selectedTab: Tab = .chat

        enum Tab: String, CaseIterable, Identifiable {
            case chat
            case inbox

            var id: String { rawValue }

            var displayName: String {
                switch self {
                case .chat: return String(localized: "Chat")
                case .inbox: return String(localized: "Inbox")
                }
            }
        }

        /// Pull any new advisory notes when the surface appears.
        @MainActor func onAppear() async {
            await inbox.refreshNotes()
        }

        @MainActor func send() async {
            await inbox.send()
        }
    }
}
