import Foundation

enum VideoDisplaySettingsStore {
    private static let key = "videoDisplaySettings"

    static func save(path: String, settings: VideoDisplaySettings) {
        guard !settings.isDefault else {
            clear(path: path)
            return
        }
        var dict = loadRaw()
        if let data = try? JSONEncoder().encode(settings) {
            dict[path] = data
        }
        UserDefaults.standard.set(dict, forKey: key)
    }

    static func settings(for path: String) -> VideoDisplaySettings {
        let dict = loadRaw()
        guard let data = dict[path],
              let settings = try? JSONDecoder().decode(VideoDisplaySettings.self, from: data) else {
            return .default
        }
        return settings
    }

    static func clear(path: String) {
        var dict = loadRaw()
        dict.removeValue(forKey: path)
        UserDefaults.standard.set(dict, forKey: key)
    }

    private static func loadRaw() -> [String: Data] {
        UserDefaults.standard.dictionary(forKey: key) as? [String: Data] ?? [:]
    }
}
