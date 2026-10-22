import ActivityKit
import Combine
import CoreData
import Foundation
import Swinject
import UIKit
import WidgetKit

@available(iOS 16.2, *) private struct ActiveActivity {
    let activity: Activity<LiveActivityAttributes>

    /// Determines if the current activity needs to be recreated.
    ///
    /// - Returns: `true` if the activity is dismissed, ended, stale, or has been active for more than 60 minutes; otherwise,
    /// `false`.
    func needsRecreation() -> Bool {
        switch activity.activityState {
        case .dismissed,
             .ended,
             .stale:
            return true
        case .active:
            break
        @unknown default:
            return true
        }
        return -activity.attributes.startDate.timeIntervalSinceNow > TimeInterval(60 * 60)
    }
}

final class LiveActivityData: ObservableObject {
    /// Determination data used to update live activity state.
    @Published var determination: DeterminationData?
    /// The most recent IoB data
    @Published var iob: Decimal?
    /// Array of glucose readings fetched from persistent storage.
    @Published var glucoseFromPersistence: [GlucoseData]?
    /// The current override data (if any).
    @Published var override: OverrideData?
    /// The current temp target data (if any).
    @Published var tempTarget: TempTargetData?
    /// The widget items displayed within the live activity.
    @Published var widgetItems: [LiveActivityAttributes.LiveActivityItem]?
}

/// A service managing live activity updates and state management.
///
/// This class handles the creation, update, and termination of live activities based on various data sources
/// (e.g. Core Data notifications, glucose updates, settings changes). It integrates with system notifications,
/// dependency injection, and user defaults to ensure that the live activity reflects the current app state.
///
/// Additionally, it supports a restart functionality (via `restartActivityFromLiveActivityIntent()`)
/// via iOS shortcuts, similar to other iOS apps like xDrip4iOS or Sweet Dreams.
@available(iOS 16.2, *) final class LiveActivityManager: Injectable, ObservableObject, SettingsObserver {
    @Injected() private var settingsManager: SettingsManager!
    @Injected() private var broadcaster: Broadcaster!
    @Injected() private var storage: FileStorage!
    @Injected() private var glucoseStorage: GlucoseStorage!
    @Injected() private var iobService: IOBService!

    private let activityAuthorizationInfo = ActivityAuthorizationInfo()
    /// Indicates whether system live activities are enabled.
    @Published private(set) var systemEnabled: Bool

    /// Returns the current Trio settings.
    private var settings: TrioSettings {
        settingsManager.settings
    }

    /// The current active live activity.
    private var currentActivity: ActiveActivity?

    /// What the home/lock-screen widgets were last reloaded with. See
    /// GlucoseWidgetReloadPolicy for when a new reading earns a reload.
    @MainActor private var lastWidgetShown: GlucoseWidgetReloadPolicy.Shown?

    private var data = LiveActivityData()

    /// Silent renewal past iOS's 8-hour limit. `nil` when the build has no APNs key.
    private let renewer = LiveActivityRenewer.makeIfConfigured()

    /// True when this build can renew silently and the setting is on.
    private var silentRenewalEnabled: Bool {
        renewer != nil && settings.liveActivitySilentRenewal
    }

    /// A dispatch queue for handling Core Data change notifications.
    private let queue = DispatchQueue(label: "LiveActivityBridge.queue", qos: .userInitiated)
    private var coreDataPublisher: AnyPublisher<Set<NSManagedObjectID>, Never>?
    private var subscriptions = Set<AnyCancellable>()

    /// Initializes a new instance of `LiveActivityBridge` and sets up observers, subscribers, and notifications.
    ///
    /// - Parameter resolver: The dependency injection resolver.
    init(resolver: Resolver) {
        coreDataPublisher =
            CoreDataStack.shared.entityChangePublisher
                .receive(on: queue)
                .share()
                .eraseToAnyPublisher()

        systemEnabled = activityAuthorizationInfo.areActivitiesEnabled
        injectServices(resolver)
        setupNotifications()
        registerHandler()
        monitorForLiveActivityAuthorizationChanges()
        broadcaster.register(SettingsObserver.self, observer: self)
        data.objectWillChange.sink { [weak self] in
            Task { @MainActor in
                // by the time this runs, the object change is done, so we see the new data here
                await self?.pushCurrentContent()
                // Home/lock-screen widgets ride the same trigger as the Live Activity,
                // so they get every reading in the background too (not only when an
                // Apple Watch is paired, which is where they used to be fed from).
                self?.updateGlucoseWidgets()
            }
        }.store(in: &subscriptions)
        loadInitialData()
        Task { @MainActor in
            self.renewer?.startObserving { [weak self] activity in
                Task { @MainActor in await self?.adoptRenewedActivity(activity) }
            }
        }
    }

    /// Sets up application notifications that trigger live activity updates when the app state changes.
    private func setupNotifications() {
        let notificationCenter = Foundation.NotificationCenter.default
        notificationCenter
            .addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil) { [weak self] _ in
                Task { @MainActor in
                    await self?.pushCurrentContent()
                    // One last reload on the way out so the widget starts from the
                    // newest reading even if recent ones were held back for budget.
                    self?.updateGlucoseWidgets(enteringBackground: true)
                }
            }
        notificationCenter
            .addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil) { [weak self] _ in
                Task { @MainActor in
                    await self?.pushCurrentContent()
                }
            }
        notificationCenter.addObserver(
            self,
            selector: #selector(loadWidgetItems),
            name: .liveActivityOrderDidChange,
            object: nil
        )
    }

    /// Called when the app settings change.
    ///
    /// This method triggers an update to the live activity content state based on the new settings.
    /// - Parameter _: The updated `TrioSettings`.
    func settingsDidChange(_: TrioSettings) {
        Task { @MainActor in
            await self.pushCurrentContent()
            self.updateGlucoseWidgets()
        }
    }

    /// Registers handlers for Core Data changes related to overrides, glucose readings, and determinations.
    private func registerHandler() {
        coreDataPublisher?.filteredByEntityName("OverrideStored").sink { [weak self] _ in
            Task { await self?.loadOverrides() }
        }.store(in: &subscriptions)

        coreDataPublisher?.filteredByEntityName("TempTargetStored").sink { [weak self] _ in
            Task { await self?.loadTempTarget() }
        }.store(in: &subscriptions)

        coreDataPublisher?.filteredByEntityName("GlucoseStored").sink { [weak self] _ in
            Task { await self?.loadGlucose() }
        }.store(in: &subscriptions)

        coreDataPublisher?.filteredByEntityName("OrefDetermination")
            .debounce(for: .seconds(2), scheduler: DispatchQueue.global(qos: .utility))
            .sink { [weak self] _ in
                Task { await self?.loadDetermination() }
            }.store(in: &subscriptions)

        iobService.iobPublisher
            .debounce(for: .seconds(2), scheduler: DispatchQueue.global(qos: .utility))
            .sink { [weak self] _ in
                self?.data.iob = self?.iobService.currentIOB
            }.store(in: &subscriptions)
    }

    /// Fetches and maps new determination data and updates the live activity content state.
    private func loadDetermination() async {
        do {
            data.determination = try await fetchAndMapDetermination()
        } catch {
            debug(
                .default,
                "[LiveActivityManager] \(DebuggingIdentifiers.failed) failed to fetch and map determination: \(error)"
            )
        }
    }

    /// Fetches and maps override data and updates the live activity content state.
    private func loadOverrides() async {
        do {
            data.override = try await fetchAndMapOverride()
        } catch {
            debug(.default, "[LiveActivityManager] \(DebuggingIdentifiers.failed) failed to fetch and map override: \(error)")
        }
    }

    /// Fetches and maps temp target data and updates the live activity content state.
    private func loadTempTarget() async {
        do {
            data.tempTarget = try await fetchAndMapTempTarget()
        } catch {
            debug(.default, "[LiveActivityManager] \(DebuggingIdentifiers.failed) failed to fetch and map temp target: \(error)")
        }
    }

    /// Handles changes to the live activity order.
    ///
    /// Loads widget items from user defaults and triggers an update to the live activity order.
    @objc private func loadWidgetItems() {
        data.widgetItems = UserDefaults.standard.loadLiveActivityOrderFromUserDefaults() ?? LiveActivityAttributes
            .LiveActivityItem.defaultItems
    }

    /// Sets up the array of glucose data from persistent storage and triggers an update to the live activity.
    private func loadGlucose() async {
        do {
            data.glucoseFromPersistence = try await fetchAndMapGlucose()
        } catch {
            debug(
                .default,
                "[LiveActivityManager] \(DebuggingIdentifiers.failed) failed to fetch glucose with error: \(error)"
            )
        }
    }

    private func loadInitialData() {
        Task {
            await self.loadGlucose()
            await self.loadOverrides()
            await self.loadTempTarget()
            await self.loadDetermination()
            self.loadWidgetItems()
        }
    }

    /// Monitors live activity authorization changes and updates the `systemEnabled` flag.
    private func monitorForLiveActivityAuthorizationChanges() {
        Task {
            for await activityState in activityAuthorizationInfo.activityEnablementUpdates {
                if activityState != systemEnabled {
                    await MainActor.run {
                        systemEnabled = activityState
                    }
                }
            }
        }
    }

    /// Pushes an update to the live activity with the specified content state.
    ///
    /// If an existing activity requires recreation or is outdated, this method ends it and starts a new one.
    /// Otherwise, it updates the current live activity.
    ///
    /// - Parameter state: The new content state to push to the live activity.
    @MainActor private func pushUpdate(_ state: LiveActivityAttributes.ContentState) async {
        if !settings.useLiveActivity || !systemEnabled {
            await endActivity()
            return
        }

        if currentActivity == nil {
            // try to restore an existing activity
            currentActivity = Activity<LiveActivityAttributes>.activities
                .max { $0.attributes.startDate < $1.attributes.startDate }.map {
                    ActiveActivity(activity: $0)
                }

            if let currentActivity {
                debug(.default, "[LiveActivityManager] Restored live activity: \(currentActivity.activity.id)")
                renewer?.observePushToken(of: currentActivity.activity)
            }
        }

        // A newer activity started by a renewal push replaces the current one.
        // Checked before the cleanup below so the new one is not ended by mistake.
        if let renewed = newerLiveActivity() {
            await adoptRenewedActivity(renewed)
        }

        // End all unknown activities except the current one
        for unknownActivity in Activity<LiveActivityAttributes>.activities
            .filter({ self.currentActivity?.activity.id != $0.id })
        {
            await unknownActivity.end(nil, dismissalPolicy: .immediate)
        }

        if let currentActivity {
            if currentActivity.needsRecreation(), UIApplication.shared.applicationState == .active {
                debug(.default, "[LiveActivityManager] Ending current activity for recreation: \(currentActivity.activity.id)")
                await endActivity()
                // After endActivity(), currentActivity is guaranteed to be nil
                // No recursive task, but explicitly restart
                debug(.default, "[LiveActivityManager] Re-pushing update after recreation.")
                await pushUpdate(state)
            } else {
                let content = ActivityContent(
                    state: state,
                    staleDate: min(state.date ?? Date.now, Date.now).addingTimeInterval(360)
                )
                // Before the update, check if currentActivity is still valid
                if let stillCurrent = self.currentActivity, stillCurrent.activity.id == currentActivity.activity.id {
                    debug(.default, "[LiveActivityManager] Updating current activity: \(stillCurrent.activity.id)")
                    await stillCurrent.activity.update(content)
                    // In the background, near the 8-hour limit, start its replacement by push.
                    if silentRenewalEnabled, let renewer {
                        await renewer.renewIfDue(
                            activity: stillCurrent.activity,
                            content: state,
                            appIsActive: UIApplication.shared.applicationState == .active
                        )
                    }
                } else {
                    debug(.default, "[LiveActivityManager] Skipped update: currentActivity changed during pushUpdate.")
                }
            }
        } else {
            // ... Activity is newly created ...
            do {
                let expired = ActivityContent(
                    state: LiveActivityAttributes
                        .ContentState(
                            unit: settings.units.rawValue,
                            bg: "--",
                            direction: nil,
                            change: "--",
                            date: Date.now,
                            highGlucose: settings.high,
                            lowGlucose: settings.low,
                            target: data.determination?.target ?? 100 as Decimal,
                            glucoseColorScheme: settings.glucoseColorScheme.rawValue,
                            useDetailedViewIOS: false,
                            useDetailedViewWatchOS: false,
                            detailedViewState: LiveActivityAttributes.ContentAdditionalState(
                                chart: [],
                                rotationDegrees: 0,
                                cob: 0,
                                iob: 0,
                                tdd: 0,
                                eventualBG: "",
                                isOverrideActive: false,
                                overrideName: "",
                                overrideDate: Date.now,
                                overrideDuration: 0,
                                overrideTarget: 0,
                                isTempTargetActive: false,
                                tempTargetName: "",
                                tempTargetDate: Date.now,
                                tempTargetDuration: 0,
                                tempTargetTarget: 0,
                                widgetItems: [],
                                minForecast: [],
                                maxForecast: [],
                                forecastLines: [],
                                forecastDisplayType: ForecastDisplayType.cone.rawValue
                            ),
                            isInitialState: true
                        ),
                    staleDate: Date.now.addingTimeInterval(60)
                )

                let activity = try requestActivity(content: expired)
                currentActivity = ActiveActivity(activity: activity)
                debug(.default, "[LiveActivityManager] Created new activity: \(activity.id)")

                // Update the newly created activity with actual data
                let updateContent = ActivityContent(
                    state: state,
                    staleDate: Date.now.addingTimeInterval(5 * 60)
                )
                await activity.update(updateContent)
                debug(.default, "[LiveActivityManager] Set initial content for new activity: \(activity.id)")
            } catch {
                debug(
                    .default,
                    "[LiveActivityManager]: Error creating new activity: \(error)"
                )
                // Reset currentActivity on error to allow retry on next update
                currentActivity = nil
            }
        }
    }

    /// Ends the current live activity and ensures that all unknown activities are terminated.
    private func endActivity() async {
        debug(.default, "[LiveActivityManager] Ending all live activities...")

        if let currentActivity {
            debug(.default, "[LiveActivityManager] Ending current activity: \(currentActivity.activity.id)")
            await currentActivity.activity.end(nil, dismissalPolicy: .immediate)
            self.currentActivity = nil
        }

        for unknownActivity in Activity<LiveActivityAttributes>.activities {
            debug(.default, "[LiveActivityManager] Ending unknown activity: \(unknownActivity.id)")
            await unknownActivity.end(nil, dismissalPolicy: .immediate)
        }

        debug(.default, "[LiveActivityManager] All live activities ended.")
    }

    /// Restarts the live activity from a Live Activity Intent.
    ///
    /// This method mimics xdrip's `restartActivityFromLiveActivityIntent()` behavior by verifying that a valid content state
    /// exists,
    /// ending the current live activity, and starting a new one using the current state.
    @MainActor func restartActivityFromLiveActivityIntent() async {
        await endActivity()

        while (currentActivity != nil && currentActivity!.activity.activityState != .ended) || Activity<LiveActivityAttributes>
            .activities.contains(where: { $0.activityState != .ended })
        {
            debug(.default, "[LiveActivityManager] Waiting for Live Activity to end...")
            try? await Task.sleep(nanoseconds: 200_000_000) // 0.2s sleep
        }

        // Add additional delay to ensure iOS has fully cleaned up the previous activity
        debug(.default, "[LiveActivityManager] Waiting additional time for iOS to clean up...")
        try? await Task.sleep(nanoseconds: 1_000_000_000) // 1s additional delay

        await pushCurrentContent()

        debug(.default, "[LiveActivityManager] Restarted Live Activity from LiveActivityIntent (via iOS Shortcut)")
    }
}

@available(iOS 16.2, *) extension LiveActivityManager {
    @MainActor func pushCurrentContent() async {
        guard let glucose = data.glucoseFromPersistence, let bg = glucose.first else {
            debug(.default, "[LiveActivityManager] pushCurrentContent: no current glucose data available")
            return
        }
        let prevGlucose = data.glucoseFromPersistence?.dropFirst().first

        guard let determination = data.determination else {
            debug(.default, "[LiveActivityManager] pushCurrentContent: no determination available")
            return
        }

        let content = LiveActivityAttributes.ContentState(
            new: bg,
            prev: prevGlucose,
            units: settings.units,
            chart: glucose,
            settings: settings,
            determination: determination,
            iob: data.iob,
            override: data.override,
            tempTarget: data.tempTarget,
            widgetItems: data.widgetItems
        )

        await pushUpdate(content)
    }
}

// MARK: - Silent renewal past the 8-hour limit

@available(iOS 16.2, *) extension LiveActivityManager {
    /// Starts a local activity. With silent renewal on it asks for a push token, and
    /// falls back to no push type if iOS refuses (for example a build signed
    /// without the push entitlement), so the activity still starts as before.
    @MainActor private func requestActivity(
        content: ActivityContent<LiveActivityAttributes.ContentState>
    ) throws -> Activity<LiveActivityAttributes> {
        let attributes = LiveActivityAttributes(startDate: Date.now)
        if silentRenewalEnabled {
            do {
                let activity = try Activity.request(attributes: attributes, content: content, pushType: .token)
                renewer?.observePushToken(of: activity)
                return activity
            } catch {
                debug(.default, "[LiveActivityManager] push-type activity refused, starting without: \(error)")
            }
        }
        return try Activity.request(attributes: attributes, content: content, pushType: nil)
    }

    /// A running activity newer than the current one, which only a renewal push starts.
    @MainActor private func newerLiveActivity() -> Activity<LiveActivityAttributes>? {
        let currentStart = currentActivity?.activity.attributes.startDate ?? .distantPast
        return Activity<LiveActivityAttributes>.activities
            .filter { $0.id != currentActivity?.activity.id }
            .filter { $0.activityState != .ended && $0.activityState != .dismissed }
            .filter { $0.attributes.startDate > currentStart }
            .max { $0.attributes.startDate < $1.attributes.startDate }
    }

    /// Makes an activity iOS started from a renewal push the current one, ends the
    /// old one and fills the new one with the full content (the push carried a
    /// lighter copy to fit APNs' 4 KB limit).
    @MainActor func adoptRenewedActivity(_ activity: Activity<LiveActivityAttributes>) async {
        guard activity.id != currentActivity?.activity.id,
              activity.activityState != .ended, activity.activityState != .dismissed,
              activity.attributes.startDate > (currentActivity?.activity.attributes.startDate ?? .distantPast)
        else { return }

        let old = currentActivity
        currentActivity = ActiveActivity(activity: activity)
        renewer?.observePushToken(of: activity)
        renewer?.didAdoptRenewedActivity()
        debug(.default, "[LiveActivityManager] Adopted renewed activity \(activity.id), replacing \(old?.activity.id ?? "none")")

        if let old {
            renewer?.forgetActivity(id: old.activity.id)
            await old.activity.end(nil, dismissalPolicy: .immediate)
        }
        await pushCurrentContent()
    }
}

// MARK: - Home and lock-screen glucose widgets

@available(iOS 16.2, *) extension LiveActivityManager {
    static let glucoseWidgetKinds = ["TrioGlucoseLockWidget", "TrioGlucoseHomeWidget"]

    /// Writes the latest reading to the App Group for the glucose widgets on every
    /// call (so any reload, including one iOS schedules itself, shows the newest
    /// data), then asks iOS to reload them only when GlucoseWidgetReloadPolicy
    /// says the change is worth one of the limited background reloads.
    @MainActor func updateGlucoseWidgets(enteringBackground: Bool = false) {
        guard let readings = data.glucoseFromPersistence, let latest = readings.first else { return }
        let units = settings.units

        func display(_ mgdl: Int) -> Double {
            units == .mmolL ? Double(truncating: Decimal(mgdl).asMmolL as NSNumber) : Double(mgdl)
        }

        func displayThreshold(_ mgdl: Decimal) -> Double {
            Double(truncating: (units == .mmolL ? mgdl.asMmolL : mgdl) as NSNumber)
        }

        // Delta only against the reading right before it (within 12 min), so a
        // gap after a sensor change never shows a misleading jump.
        var delta = ""
        if let previous = readings.dropFirst().first,
           latest.date.timeIntervalSince(previous.date) <= 12 * 60
        {
            delta = LiveActivityAttributes.ContentState.formatGlucose(
                latest.glucose - previous.glucose,
                units: units,
                forceSign: true
            )
        }

        let inRange = Decimal(latest.glucose) >= settings.low && Decimal(latest.glucose) <= settings.high
        let history = readings.prefix(48).reversed().map {
            WidgetGlucosePoint(date: $0.date, glucose: display($0.glucose))
        }
        let iob = data.iob.flatMap { Formatter.decimalFormatterWithTwoFractionDigits.string(from: $0 as NSNumber) }
        let cob = data.determination.flatMap { Formatter.integerFormatter.string(from: NSNumber(value: $0.cob)) }

        GlucoseWidgetData(
            glucose: LiveActivityAttributes.ContentState.formatGlucose(latest.glucose, units: units, forceSign: false),
            trend: (latest.direction?.symbol as? String) ?? "",
            delta: delta,
            iob: iob,
            cob: cob,
            colorString: inRange ? "#ffffff" : "#ff0000",
            date: latest.date,
            history: history.count >= 2 ? Array(history) : nil,
            low: displayThreshold(settings.low),
            high: displayThreshold(settings.high),
            lastLoopDate: data.determination?.date
        ).save()

        let shown = GlucoseWidgetReloadPolicy.Shown(
            readingDate: latest.date,
            glucoseMgdL: latest.glucose,
            trend: (latest.direction?.symbol as? String) ?? "",
            inRange: inRange,
            units: units.rawValue
        )
        guard GlucoseWidgetReloadPolicy.shouldReload(
            new: shown,
            last: lastWidgetShown,
            appIsActive: UIApplication.shared.applicationState == .active,
            enteringBackground: enteringBackground
        ) else { return }
        lastWidgetShown = shown
        for kind in Self.glucoseWidgetKinds {
            WidgetCenter.shared.reloadTimelines(ofKind: kind)
        }
        debug(.default, "[LiveActivityManager] Glucose widgets reloaded for reading at \(latest.date)")
    }
}
