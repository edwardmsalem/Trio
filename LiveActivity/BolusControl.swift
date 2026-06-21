import AppIntents
import SwiftUI
import WidgetKit

/// Control Center / lock-screen-button control that opens Trio's bolus entry
/// screen. It deep-links into the app (never doses directly — bolusing always
/// goes through the in-app confirmation flow).
struct BolusControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "TrioBolusControl") {
            ControlWidgetButton(action: OpenBolusControlIntent()) {
                Label("Bolus", systemImage: "syringe.fill")
            }
        }
        .displayName("Trio Bolus")
        .description("Open Trio's carb/bolus entry screen.")
    }
}

/// Control Center button that opens the app to the carb/bolus screen via the
/// Trio:// deep link. Opening (not dosing) is deliberate.
struct OpenBolusControlIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Bolus Entry"
    static var description = IntentDescription("Opens Trio's carb/bolus entry screen.")
    static var openAppWhenRun: Bool = true

    @MainActor func perform() async throws -> some IntentResult & OpensIntent {
        .result(opensIntent: OpenURLIntent(URL(string: "Trio://treatments")!))
    }
}

/// Companion meal control (AI meal scanner). Same open-only behavior.
struct MealControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "TrioMealControl") {
            ControlWidgetButton(action: OpenMealControlIntent()) {
                Label("Meal", systemImage: "fork.knife")
            }
        }
        .displayName("Trio Meal")
        .description("Open Trio's AI meal scanner.")
    }
}

struct OpenMealControlIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Meal Scanner"
    static var description = IntentDescription("Opens Trio's AI meal scanner.")
    static var openAppWhenRun: Bool = true

    @MainActor func perform() async throws -> some IntentResult & OpensIntent {
        .result(opensIntent: OpenURLIntent(URL(string: "Trio://mealScan")!))
    }
}
