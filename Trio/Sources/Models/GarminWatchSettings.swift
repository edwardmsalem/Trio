import Foundation

// MARK: - Garmin Data Type Settings

/// Primary attribute selection for Garmin watchface and datafield.
/// Determines whether to display COB, ISF, or Sensitivity Ratio alongside glucose data.
/// Used by both Trio and SwissAlpine watchfaces.
enum GarminPrimaryAttributeChoice: String, JSON, CaseIterable, Identifiable, Codable, Hashable {
    var id: String { rawValue }

    case cob
    case isf
    case sensRatio

    var displayName: String {
        switch self {
        case .cob:
            return String(localized: "COB", comment: "")
        case .isf:
            return String(localized: "ISF", comment: "")
        case .sensRatio:
            return String(localized: "Sens Ratio", comment: "")
        }
    }
}

/// Secondary attribute selection for both Trio and SwissAlpine watchfaces.
/// Determines whether to display Temp Basal Rate or Eventual BG.
enum GarminSecondaryAttributeChoice: String, JSON, CaseIterable, Identifiable, Codable, Hashable {
    var id: String { rawValue }

    case tbr
    case eventualBG

    var displayName: String {
        switch self {
        case .tbr:
            return String(localized: "TBR", comment: "")
        case .eventualBG:
            return String(localized: "evBG", comment: "")
        }
    }
}

// MARK: - Garmin Watchface Setting

/// Defines the available Garmin watchfaces with their associated UUIDs.
enum GarminWatchface: String, JSON, CaseIterable, Identifiable, Codable, Hashable {
    var id: String { rawValue }

    case trio
    case swissalpine
    /// Not a watchface but a Connect IQ watch app that republishes the payload as
    /// complications, so any watchface with complication slots can show Trio data.
    /// It takes the watchface slot because someone on complications is by definition
    /// not running one of the Trio watchfaces, which leaves that slot free.
    case complication
    /// The sideloaded garmin-glance faces (github.com/edwardmsalem/garmin-glance). They
    /// read the same array the Trio watchface does, taking the first entry.
    case aviator
    case navitimer
    case offshore
    case perpetual
    case quadrant
    case chronometer
    case iwcPerpetual
    case grandmaster
    case yachtMaster
    case daytona
    case skyDweller
    case yachtMasterII
    case fieldGMT
    case luminor
    case u50
    case premier
    case lange
    case apSport

    var displayName: String {
        switch self {
        case .trio:
            return String(localized: "Trio", comment: "")
        case .swissalpine:
            return String(localized: "Swissalpine", comment: "")
        case .complication:
            return String(localized: "Complication", comment: "")
        case .aviator:
            return String(localized: "Aviator", comment: "Garmin watchface name")
        case .navitimer:
            return String(localized: "Navitimer", comment: "Garmin watchface name")
        case .offshore:
            return String(localized: "Offshore", comment: "Garmin watchface name")
        case .perpetual:
            return String(localized: "Perpetual", comment: "Garmin watchface name")
        case .quadrant:
            return String(localized: "Enamel Quadrant", comment: "Garmin watchface name")
        case .chronometer:
            return String(localized: "Chronometer", comment: "Garmin watchface name")
        case .iwcPerpetual:
            return String(localized: "IWC Perpetual", comment: "Garmin watchface name")
        case .grandmaster:
            return String(localized: "Grandmaster", comment: "Garmin watchface name")
        case .yachtMaster:
            return String(localized: "Yacht-Master", comment: "Garmin watchface name")
        case .daytona:
            return String(localized: "Daytona", comment: "Garmin watchface name")
        case .skyDweller:
            return String(localized: "Sky-Dweller", comment: "Garmin watchface name")
        case .yachtMasterII:
            return String(localized: "Yacht-Master II", comment: "Garmin watchface name")
        case .fieldGMT:
            return String(localized: "Field GMT", comment: "Garmin watchface name")
        case .luminor:
            return String(localized: "Luminor", comment: "Garmin watchface name")
        case .u50:
            return String(localized: "U50", comment: "Garmin watchface name")
        case .premier:
            return String(localized: "Premier", comment: "Garmin watchface name")
        case .lange:
            return String(localized: "Lange", comment: "Garmin watchface name")
        case .apSport:
            return String(localized: "AP Sport", comment: "Garmin watchface name")
        }
    }

    /// The sideloaded garmin-glance faces. Trio pushes to every one that is installed, so the
    /// wearer can switch faces on the watch without also changing the pick in Trio.
    static var garminGlanceFaces: [GarminWatchface] {
        allCases.filter { ![.trio, .swissalpine, .complication].contains($0) }
    }

    /// The UUID for the watchface applications in Garmin Connect IQ
    var watchfaceUUID: UUID? {
        switch self {
        case .trio:
            // return UUID(uuidString: "EC3420F6-027D-49B3-B45F-D81D6D3ED90A")  // local build
            // return UUID(uuidString: "81204522-B1BE-4E19-8E6E-C4032AAF8C6D") // ConnectIQ test build
            return UUID(uuidString: "7a121867-140e-41ba-9982-2e82e2aa6579") // ConnectIQ live build
        case .swissalpine:
            // return UUID(uuidString: "5A643C13-D5A7-40D4-B809-84789FDF4A1F") // ConnectIQ test build
            return UUID(uuidString: "4cea4efd-4aaf-4db4-8891-ef36dde14303") // ConnectIQ live build
        case .complication:
            // return UUID(uuidString: "a897ce34-1135-4632-b855-1c75f1ec27bf") // ConnectIQ beta build
            return UUID(uuidString: "0986fd19-604b-4bcb-a931-6f8621738682") // ConnectIQ live build
        case .aviator:
            return UUID(uuidString: "3E7C21A9-84D5-4B60-9C13-7A2E5F6D0B48")
        case .navitimer:
            return UUID(uuidString: "7C1A9F42-6D3B-4E58-9A21-5F0C8B4D2E77")
        case .offshore:
            return UUID(uuidString: "BADE0AD0-BFB8-44D4-B867-95AFF811FB74")
        case .perpetual:
            return UUID(uuidString: "63C1451C-1196-4EC3-A39B-03DC00BF63F8")
        case .quadrant:
            return UUID(uuidString: "A92C0A61-91C0-45C1-8F04-0F7AB5F92350")
        case .chronometer:
            return UUID(uuidString: "C7251B90-3A4E-4F68-9D12-6B8E0A5C7F33")
        case .iwcPerpetual:
            return UUID(uuidString: "3C18D242-AC94-4C1D-9421-105036042026")
        case .grandmaster:
            return UUID(uuidString: "EB6C5190-0512-413B-871A-6300AA1E2026")
        case .yachtMaster:
            return UUID(uuidString: "D5178369-7E4A-40D2-B636-275DF97FA054")
        case .daytona:
            return UUID(uuidString: "347CD3AC-6207-4088-AE01-DC3245B49F08")
        case .skyDweller:
            return UUID(uuidString: "8D75E2C9-B419-4C0F-976C-CB593DCD67C4")
        case .yachtMasterII:
            return UUID(uuidString: "62F190D9-5E08-4708-B1C8-43991496375B")
        case .fieldGMT:
            return UUID(uuidString: "A47DBE30-91C6-4875-B052-AE83DFA74619")
        case .luminor:
            return UUID(uuidString: "B17AF08D-6F6E-4770-9F15-35AB73DDA128")
        case .u50:
            return UUID(uuidString: "6758E4AA-2B40-4AA8-8C1B-84A3751F7F93")
        case .premier:
            return UUID(uuidString: "867129CF-432B-426B-AB31-2B66882D474E")
        case .lange:
            return UUID(uuidString: "EC2FB1B7-7F87-4F05-ABAF-1816B196AB91")
        case .apSport:
            return UUID(uuidString: "9BE57722-AB1A-49D5-BB48-408CCBB36E51")
        }
    }
}

// MARK: - Garmin Datafield Setting

/// Defines the available Garmin datafields with their associated UUIDs.
enum GarminDatafield: String, JSON, CaseIterable, Identifiable, Codable, Hashable {
    var id: String { rawValue }

    case trio
    case swissalpine
    case none

    var displayName: String {
        switch self {
        case .trio:
            return String(localized: "Trio", comment: "")
        case .swissalpine:
            return String(localized: "Swissalpine", comment: "")
        case .none:
            return String(localized: "None", comment: "")
        }
    }

    /// The UUID for the datafield application in Garmin Connect IQ
    var datafieldUUID: UUID? {
        switch self {
        case .trio:
            // return UUID(uuidString: "71cf0982-ca41-42a5-8441-ea81d36056c3")  // local build
            // return UUID(uuidString: "f07f4ef9-108b-4397-95c9-217b5173412e")  // ConnectIQ test build
            return UUID(uuidString: "3d9b6528-8c84-459a-bbab-989b5f001ebd") // ConnectIQ live build
        case .swissalpine:
            // return UUID(uuidString: "7A2268F6-3381-4474-81BD-0A3E7F458CB7") // ConnectIQ test build
            return UUID(uuidString: "dec5292a-74b0-41bc-8e45-cd93f1d5e137") // ConnectIQ live build
        case .none:
            return nil
        }
    }
}

// MARK: - Garmin Watch Settings Group

/// Groups related Garmin watch settings together for easier management.
/// Both watchfaces use the same settings: primaryAttributeChoice and secondaryAttributeChoice.
struct GarminWatchSettings: Codable, Hashable {
    var watchface: GarminWatchface = .trio
    var datafield: GarminDatafield = .trio
    var primaryAttributeChoice: GarminPrimaryAttributeChoice = .cob
    var secondaryAttributeChoice: GarminSecondaryAttributeChoice = .tbr
    var isWatchfaceDataEnabled: Bool = false
}
