import Foundation

enum VideoDisplaySettingsStore {
    private static let key = "videoDisplaySettings"

    static func save(path: String, settings: VideoDisplaySettings, defaults: UserDefaults = .standard) {
        guard !settings.isDefault else {
            clear(path: path, defaults: defaults)
            return
        }
        var dict = loadRaw(defaults: defaults)
        if let data = try? JSONEncoder().encode(settings) {
            dict[path] = data
        }
        defaults.set(dict, forKey: key)
    }

    static func settings(for path: String, defaults: UserDefaults = .standard) -> VideoDisplaySettings {
        let dict = loadRaw(defaults: defaults)
        guard let data = dict[path],
              let settings = try? JSONDecoder().decode(VideoDisplaySettings.self, from: data) else {
            return .default
        }
        return settings
    }

    static func clear(path: String, defaults: UserDefaults = .standard) {
        var dict = loadRaw(defaults: defaults)
        dict.removeValue(forKey: path)
        defaults.set(dict, forKey: key)
    }

    private static func loadRaw(defaults: UserDefaults) -> [String: Data] {
        defaults.dictionary(forKey: key) as? [String: Data] ?? [:]
    }
}
