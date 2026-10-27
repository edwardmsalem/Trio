import Foundation
import Observation
import SwiftUI

extension AAPSDosing {
    @Observable final class StateModel: BaseStateModel<Provider> {
        var enabled: Bool = true { didSet { persist() } }
        var dynamicISF: Bool = true { didSet { persist() } }
        var adjustmentFactorPercent: Int = 100 { didSet { persist() } }
        var adjustSensitivityFromTDD: Bool = true { didSet { persist() } }
        var tierOrder: AAPSTierOrder = .onTopOfDynamic { didSet { persist() } }
        var startingTDD: Int = 78 { didSet { persist() } }
        var guardSeesUpcomingCarbs: Bool = true { didSet { persist() } }

        private var loaded = false

        override func subscribe() {
            let s = provider.settings
            enabled = s.enabled
            dynamicISF = s.dynamicISF
            adjustmentFactorPercent = s.adjustmentFactorPercent
            adjustSensitivityFromTDD = s.adjustSensitivityFromTDD
            tierOrder = s.tierOrder
            startingTDD = s.startingTDD
            guardSeesUpcomingCarbs = s.guardSeesUpcomingCarbs
            loaded = true
        }

        private func persist() {
            guard loaded else { return }
            provider.save(AAPSDosingSettings(
                enabled: enabled,
                dynamicISF: dynamicISF,
                adjustmentFactorPercent: adjustmentFactorPercent,
                adjustSensitivityFromTDD: adjustSensitivityFromTDD,
                tierOrder: tierOrder,
                startingTDD: startingTDD,
                guardSeesUpcomingCarbs: guardSeesUpcomingCarbs
            ))
        }
    }
}
