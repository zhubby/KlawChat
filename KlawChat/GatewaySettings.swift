import Foundation

struct GatewaySettings: Equatable {
    var baseURLString: String
    var token: String
    var streamEnabled: Bool
    var lastSessionKey: String?

    static let defaults = GatewaySettings(
        baseURLString: "http://127.0.0.1:18080",
        token: "",
        streamEnabled: true,
        lastSessionKey: nil
    )
}

protocol GatewaySettingsStore {
    func load() -> GatewaySettings
    func save(_ settings: GatewaySettings)
}

struct UserDefaultsGatewaySettingsStore: GatewaySettingsStore {
    private enum Key {
        static let baseURLString = "gateway.baseURLString"
        static let token = "gateway.token"
        static let streamEnabled = "gateway.streamEnabled"
        static let lastSessionKey = "gateway.lastSessionKey"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> GatewaySettings {
        GatewaySettings(
            baseURLString: defaults.string(forKey: Key.baseURLString) ?? GatewaySettings.defaults.baseURLString,
            token: defaults.string(forKey: Key.token) ?? GatewaySettings.defaults.token,
            streamEnabled: defaults.object(forKey: Key.streamEnabled) as? Bool ?? GatewaySettings.defaults.streamEnabled,
            lastSessionKey: defaults.string(forKey: Key.lastSessionKey)
        )
    }

    func save(_ settings: GatewaySettings) {
        defaults.set(settings.baseURLString, forKey: Key.baseURLString)
        defaults.set(settings.token, forKey: Key.token)
        defaults.set(settings.streamEnabled, forKey: Key.streamEnabled)
        defaults.set(settings.lastSessionKey, forKey: Key.lastSessionKey)
    }
}
