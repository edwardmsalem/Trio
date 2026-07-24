import ActivityKit
import Foundation

struct LiveActivityAttributes: ActivityAttributes {
    enum LiveActivityItem: String, Hashable, Codable, Equatable {
        case currentGlucoseLarge
        case currentGlucose
        case iob
        case cob
        case updatedLabel
        case totalDailyDose
        case eventualGlucose
        case empty

        static let defaultItems: [Self] = [.currentGlucoseLarge, .iob, .cob, .updatedLabel]
    }

    struct ContentState: Codable, Hashable {
        let unit: String
        let bg: String
        let direction: String?
        let change: String
        let date: Date?
        let highGlucose: Decimal
        let lowGlucose: Decimal
        let target: Decimal
        let glucoseColorScheme: String
        let useDetailedViewIOS: Bool
        let useDetailedViewWatchOS: Bool
        let detailedViewState: ContentAdditionalState

        /// true for the first state that is set on the activity
        let isInitialState: Bool
    }

    struct ContentAdditionalState: Codable, Hashable {
        let chart: [ChartItem]
        let rotationDegrees: Double
        let cob: Decimal
        let iob: Decimal
        let tdd: Decimal
        /// Decoded leniently (see init(from:)): an activity persisted by an older app
        /// version lacks this key, and a strict decode would strand the running
        /// activity after an update (blank lock screen until it expires).
        let eventualBG: String
        let isOverrideActive: Bool
        let overrideName: String
        let overrideDate: Date
        let overrideDuration: Decimal
        let overrideTarget: Decimal
        let isTempTargetActive: Bool
        let tempTargetName: String
        let tempTargetDate: Date
        let tempTargetDuration: Decimal
        let tempTargetTarget: Decimal
        let widgetItems: [LiveActivityItem]

        init(
            chart: [ChartItem],
            rotationDegrees: Double,
            cob: Decimal,
            iob: Decimal,
            tdd: Decimal,
            eventualBG: String,
            isOverrideActive: Bool,
            overrideName: String,
            overrideDate: Date,
            overrideDuration: Decimal,
            overrideTarget: Decimal,
            isTempTargetActive: Bool,
            tempTargetName: String,
            tempTargetDate: Date,
            tempTargetDuration: Decimal,
            tempTargetTarget: Decimal,
            widgetItems: [LiveActivityItem]
        ) {
            self.chart = chart
            self.rotationDegrees = rotationDegrees
            self.cob = cob
            self.iob = iob
            self.tdd = tdd
            self.eventualBG = eventualBG
            self.isOverrideActive = isOverrideActive
            self.overrideName = overrideName
            self.overrideDate = overrideDate
            self.overrideDuration = overrideDuration
            self.overrideTarget = overrideTarget
            self.isTempTargetActive = isTempTargetActive
            self.tempTargetName = tempTargetName
            self.tempTargetDate = tempTargetDate
            self.tempTargetDuration = tempTargetDuration
            self.tempTargetTarget = tempTargetTarget
            self.widgetItems = widgetItems
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            chart = try c.decode([ChartItem].self, forKey: .chart)
            rotationDegrees = try c.decode(Double.self, forKey: .rotationDegrees)
            cob = try c.decode(Decimal.self, forKey: .cob)
            iob = try c.decode(Decimal.self, forKey: .iob)
            tdd = try c.decode(Decimal.self, forKey: .tdd)
            // Lenient: missing on activities persisted by older builds.
            eventualBG = try c.decodeIfPresent(String.self, forKey: .eventualBG) ?? ""
            isOverrideActive = try c.decode(Bool.self, forKey: .isOverrideActive)
            overrideName = try c.decode(String.self, forKey: .overrideName)
            overrideDate = try c.decode(Date.self, forKey: .overrideDate)
            overrideDuration = try c.decode(Decimal.self, forKey: .overrideDuration)
            overrideTarget = try c.decode(Decimal.self, forKey: .overrideTarget)
            isTempTargetActive = try c.decode(Bool.self, forKey: .isTempTargetActive)
            tempTargetName = try c.decode(String.self, forKey: .tempTargetName)
            tempTargetDate = try c.decode(Date.self, forKey: .tempTargetDate)
            tempTargetDuration = try c.decode(Decimal.self, forKey: .tempTargetDuration)
            tempTargetTarget = try c.decode(Decimal.self, forKey: .tempTargetTarget)
            widgetItems = try c.decodeIfPresent([LiveActivityItem].self, forKey: .widgetItems) ?? []
        }
    }

    struct ChartItem: Codable, Hashable {
        let value: Decimal
        let date: Date
    }

    let startDate: Date
}
