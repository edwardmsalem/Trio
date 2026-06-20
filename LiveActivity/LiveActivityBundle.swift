import SwiftUI
import WidgetKit

@main struct LiveActivityBundle: WidgetBundle {
    var body: some Widget {
        LiveActivity()
        MealScanWidget()
        TrioGlucoseLockWidget()
        TrioGlucoseHomeWidget()
        // Control Center / lock-screen-button controls (iOS 18+)
        BolusControl()
        MealControl()
    }
}
