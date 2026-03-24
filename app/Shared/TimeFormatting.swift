import Foundation

enum TimeFormatting {
    static func display(_ us: Int64) -> String {
        let totalSeconds = Int(us / 1_000_000)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    static func debug(_ us: Int64) -> String {
        let totalSeconds = Double(us) / 1_000_000.0
        let minutes = Int(totalSeconds) / 60
        let seconds = totalSeconds - Double(minutes * 60)
        return String(format: "%d:%06.3f", minutes, seconds)
    }
}
