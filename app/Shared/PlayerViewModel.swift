import Foundation
import Combine

class PlayerViewModel: ObservableObject {
    let bridge = PlayerBridge()

    @Published var isPlaying = false
    @Published var currentPosition: Int64 = 0
    @Published var duration: Int64 = 0
    @Published var currentSubtitle: SubtitleData?
    @Published var mediaTitle: String = ""

    private var positionTimer: Timer?

    func open(path: String) {
        guard bridge.open(path: path) else { return }
        duration = bridge.duration

        // Extract title from path
        let url = URL(fileURLWithPath: path)
        mediaTitle = url.deletingPathExtension().lastPathComponent
    }

    func play() {
        bridge.play()
        isPlaying = true
        startPositionUpdates()
    }

    func pause() {
        bridge.pause()
        isPlaying = false
        stopPositionUpdates()
    }

    func togglePlayPause() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    func seek(to fraction: Double) {
        let target = Int64(fraction * Double(duration))
        bridge.seek(to: target)
        currentPosition = target
    }

    func stop() {
        bridge.stop()
        isPlaying = false
        currentPosition = 0
        stopPositionUpdates()
    }

    var positionFraction: Double {
        guard duration > 0 else { return 0 }
        return Double(currentPosition) / Double(duration)
    }

    var positionText: String {
        formatTime(currentPosition)
    }

    var durationText: String {
        formatTime(duration)
    }

    private func startPositionUpdates() {
        positionTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.currentPosition = self.bridge.position
            self.currentSubtitle = self.bridge.getSubtitle(at: self.currentPosition)
        }
    }

    private func stopPositionUpdates() {
        positionTimer?.invalidate()
        positionTimer = nil
    }

    private func formatTime(_ us: Int64) -> String {
        let totalSeconds = Int(us / 1_000_000)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}
