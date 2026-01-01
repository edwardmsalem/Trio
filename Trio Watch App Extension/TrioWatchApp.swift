import SwiftUI
import WatchKit
import WidgetKit

@main struct TrioWatchApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @WKApplicationDelegateAdaptor private var appDelegate: WatchAppDelegate

    var body: some Scene {
        WindowGroup {
            TrioMainWatchView()
        }
        .onChange(of: scenePhase) { _, newScenePhase in
            if newScenePhase == .background {
                Task {
                    await WatchLogger.shared.flushPersistedLogs()
                }
                // Schedule background refresh to keep complications updated
                WatchAppDelegate.scheduleBackgroundRefresh()
            }
        }
    }
}

// MARK: - Watch App Delegate for Background Refresh

class WatchAppDelegate: NSObject, WKApplicationDelegate {

    /// Schedule background refresh to run periodically
    static func scheduleBackgroundRefresh() {
        // Schedule refresh for 5 minutes from now
        let refreshDate = Date().addingTimeInterval(5 * 60)

        WKApplication.shared().scheduleBackgroundRefresh(
            withPreferredDate: refreshDate,
            userInfo: nil
        ) { error in
            if let error = error {
                Task {
                    await WatchLogger.shared.log("⚠️ Failed to schedule background refresh: \(error)")
                }
            } else {
                Task {
                    await WatchLogger.shared.log("✅ Scheduled background refresh for \(refreshDate)")
                }
            }
        }
    }

    /// Handle background refresh task
    func handle(_ backgroundTasks: Set<WKRefreshBackgroundTask>) {
        for task in backgroundTasks {
            switch task {
            case let backgroundTask as WKApplicationRefreshBackgroundTask:
                Task {
                    await WatchLogger.shared.log("🔄 Background refresh triggered")
                }

                // Request fresh data from iPhone
                WatchState.shared.requestWatchStateUpdate()

                // Reload complications to show current data or staleness
                WidgetCenter.shared.reloadAllTimelines()

                // Schedule next refresh
                Self.scheduleBackgroundRefresh()

                // Mark task complete
                backgroundTask.setTaskCompletedWithSnapshot(false)

            default:
                task.setTaskCompletedWithSnapshot(false)
            }
        }
    }
}
