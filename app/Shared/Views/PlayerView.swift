import SwiftUI

struct PlayerView: View {
    @ObservedObject var viewModel: PlayerViewModel
    let onBack: () -> Void

    @State private var showControls = true
    @State private var hideControlsTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            // Video layer
            MetalPlayerView(playerBridge: viewModel.bridge)
                .ignoresSafeArea()

            // Subtitle overlay
            SubtitleOverlayView(subtitle: viewModel.currentSubtitle)

            // Controls overlay
            if showControls {
                VStack {
                    // Top bar
                    HStack {
                        Button(action: onBack) {
                            Image(systemName: "chevron.left")
                                .font(.title2)
                                .fontWeight(.semibold)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.white)

                        Text(viewModel.mediaTitle)
                            .font(.headline)
                            .foregroundStyle(.white)

                        Spacer()
                    }
                    .padding()
                    .background(
                        LinearGradient(colors: [.black.opacity(0.6), .clear],
                                       startPoint: .top, endPoint: .bottom)
                    )

                    Spacer()

                    // Bottom controls
                    PlayerControlsView(viewModel: viewModel)
                }
            }
        }
        .background(.black)
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) {
                showControls.toggle()
            }
            scheduleHideControls()
        }
        .onAppear {
            scheduleHideControls()
        }
    }

    private func scheduleHideControls() {
        hideControlsTask?.cancel()
        hideControlsTask = Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000) // 4 seconds
            if !Task.isCancelled {
                await MainActor.run {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        showControls = false
                    }
                }
            }
        }
    }
}
