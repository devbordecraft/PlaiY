import Foundation

enum ResumeStore {
    private static let key = "resumePositions"
    private static let titlesKey = "resumeTitles"
    private static let minPositionUs: Int64 = 30_000_000  // 30s
    private static let maxFraction: Double = 0.95

    #if os(tvOS)
    private nonisolated(unsafe) static let defaults = UserDefaults(suiteName: "group.com.plaiy.app.tv") ?? .standard
    #else
    private nonisolated(unsafe) static let defaults = UserDefaults.standard
    #endif

    static func save(path: String, positionUs: Int64, durationUs: Int64, title: String? = nil) {
        guard durationUs > 0 else { return }
        let fraction = Double(positionUs) / Double(durationUs)
        guard positionUs > minPositionUs && fraction < maxFraction else {
            clear(path: path)
            return
        }
        var dict = defaults.dictionary(forKey: key) as? [String: Int64] ?? [:]
        dict[path] = positionUs
        defaults.set(dict, forKey: key)

        if let title {
            var titles = defaults.dictionary(forKey: titlesKey) as? [String: String] ?? [:]
            titles[path] = title
            defaults.set(titles, forKey: titlesKey)
        }
    }

    static func position(for path: String) -> Int64? {
        let dict = defaults.dictionary(forKey: key) as? [String: Int64] ?? [:]
        return dict[path]
    }

    static func clear(path: String) {
        var dict = defaults.dictionary(forKey: key) as? [String: Int64] ?? [:]
        dict.removeValue(forKey: path)
        defaults.set(dict, forKey: key)

        var titles = defaults.dictionary(forKey: titlesKey) as? [String: String] ?? [:]
        titles.removeValue(forKey: path)
        defaults.set(titles, forKey: titlesKey)
    }

    /// All saved resume items for Top Shelf display.
    static func allResumeItems() -> [(path: String, positionUs: Int64, title: String)] {
        let dict = defaults.dictionary(forKey: key) as? [String: Int64] ?? [:]
        let titles = defaults.dictionary(forKey: titlesKey) as? [String: String] ?? [:]
        return dict.map { (path, positionUs) in
            let title = titles[path] ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            return (path: path, positionUs: positionUs, title: title)
        }
    }
}
