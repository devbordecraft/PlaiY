import Foundation

enum ResumeStore {
    private static let key = "resumePositions"
    private static let minPositionUs: Int64 = 30_000_000  // 30s
    private static let maxFraction: Double = 0.95

    static func save(path: String, positionUs: Int64, durationUs: Int64) {
        guard durationUs > 0 else { return }
        let fraction = Double(positionUs) / Double(durationUs)
        guard positionUs > minPositionUs && fraction < maxFraction else {
            clear(path: path)
            return
        }
        var dict = UserDefaults.standard.dictionary(forKey: key) as? [String: Int64] ?? [:]
        dict[path] = positionUs
        UserDefaults.standard.set(dict, forKey: key)
    }

    static func position(for path: String) -> Int64? {
        let dict = UserDefaults.standard.dictionary(forKey: key) as? [String: Int64] ?? [:]
        return dict[path]
    }

    static func clear(path: String) {
        var dict = UserDefaults.standard.dictionary(forKey: key) as? [String: Int64] ?? [:]
        dict.removeValue(forKey: path)
        UserDefaults.standard.set(dict, forKey: key)
    }
}
