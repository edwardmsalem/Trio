import Foundation

enum AAPSDosing {
    enum Config {}
}

protocol AAPSDosingProvider: Provider {
    var settings: AAPSDosingSettings { get }
    func save(_ settings: AAPSDosingSettings)
}
