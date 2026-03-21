import SwiftUI

struct PlayerControlsView: View {
    @ObservedObject var viewModel: PlayerViewModel

    var body: some View {
        VStack(spacing: 12) {
            // Seek bar
            VStack(spacing: 4) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        // Background
                        Capsule()
                            .fill(.white.opacity(0.3))
                            .frame(height: 4)

                        // Progress
                        Capsule()
                            .fill(.white)
                            .frame(width: max(0, geo.size.width * viewModel.positionFraction),
                                   height: 4)
                    }
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                let fraction = max(0, min(1, value.location.x / geo.size.width))
                                viewModel.seek(to: fraction)
                            }
                    )
                }
                .frame(height: 20)

                // Time labels
                HStack {
                    Text(viewModel.positionText)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                        .monospacedDigit()
                    Spacer()
                    Text(viewModel.durationText)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                        .monospacedDigit()
                }
            }

            // Playback controls
            HStack(spacing: 32) {
                // Skip backward
                Button {
                    let target = max(0, viewModel.currentPosition - 10_000_000)
                    viewModel.bridge.seek(to: target)
                } label: {
                    Image(systemName: "gobackward.10")
                        .font(.title2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)

                // Play/Pause
                Button {
                    viewModel.togglePlayPause()
                } label: {
                    Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                        .font(.largeTitle)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)

                // Skip forward
                Button {
                    let target = min(viewModel.duration, viewModel.currentPosition + 10_000_000)
                    viewModel.bridge.seek(to: target)
                } label: {
                    Image(systemName: "goforward.10")
                        .font(.title2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 20)
        .background(
            LinearGradient(colors: [.clear, .black.opacity(0.7)],
                           startPoint: .top, endPoint: .bottom)
        )
    }
}
