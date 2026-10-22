import Foundation

extension AAPSDosing {
    final class Provider: BaseProvider, AAPSDosingProvider {
        var settings: AAPSDosingSettings {
            storage.retrieve(OpenAPS.Settings.aapsDosing, as: AAPSDosingSettings.self) ?? .default
        }

        func save(_ settings: AAPSDosingSettings) {
            storage.save(settings, as: OpenAPS.Settings.aapsDosing)
        }
    }
}
