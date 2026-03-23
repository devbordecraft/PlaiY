import SwiftUI

struct PlayerView: View {
    @ObservedObject var viewModel: PlayerViewModel
    let resumePosition: Int64?
    let autoplay: Bool
    let onBack: () -> Void

    @State private var showControls = true
    @State private var showSettings = false
    @State private var showResumePrompt = false
    @State private var hideControlsTask: Task<Void, Never>?
    @State private var resumeDismissTask: Task<Void, Never>?
    @FocusState private var isPlayerFocused: Bool

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

                        #if os(macOS)
                        Button {
                            toggleFullScreen()
                        } label: {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.title2)
                                .fontWeight(.semibold)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.white)
                        #endif

                        Button {
                            viewModel.showDebugOverlay.toggle()
                        } label: {
                            Image(systemName: "ant")
                                .font(.title2)
                                .fontWeight(.semibold)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(viewModel.showDebugOverlay ? .green : .white)

                        Button {
                            withAnimation(.easeInOut(duration: 0.25)) {
                                showSettings.toggle()
                            }
                            if showSettings {
                                hideControlsTask?.cancel()
                            } else {
                                scheduleHideControls()
                            }
                        } label: {
                            Image(systemName: "gearshape")
                                .font(.title2)
                                .fontWeight(.semibold)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.white)
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

            // Debug overlay (top-left, always visible when toggled)
            if viewModel.showDebugOverlay, let stats = viewModel.playbackStats {
                VStack {
                    HStack {
                        DebugOverlayView(stats: stats)
                            .padding(8)
                        Spacer()
                    }
                    Spacer()
                }
                .allowsHitTesting(false)
            }

            // Settings panel overlay
            if showSettings {
                TrackSelectionView(
                    viewModel: viewModel,
                    isPresented: $showSettings
                )
            }

            // Resume prompt overlay
            if showResumePrompt, let pos = resumePosition {
                VStack {
                    Spacer()
                    HStack(spacing: 16) {
                        Button {
                            dismissResumePrompt()
                            viewModel.bridge.seek(to: pos)
                            viewModel.play()
                        } label: {
                            Label("Resume from \(formatTime(pos))", systemImage: "play.fill")
                                .fontWeight(.semibold)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.white.opacity(0.2))

                        Button {
                            dismissResumePrompt()
                            viewModel.play()
                        } label: {
                            Text("Start from Beginning")
                        }
                        .buttonStyle(.bordered)
                        .tint(.white.opacity(0.3))
                    }
                    .font(.callout)
                    .foregroundStyle(.white)
                    .padding(20)
                    .background(.ultraThinMaterial.opacity(0.8))
                    .background(.black.opacity(0.4))
                    .cornerRadius(14)
                    .padding(.bottom, 100)
                }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .background(.black)
        .onTapGesture {
            if showSettings {
                withAnimation(.easeInOut(duration: 0.25)) {
                    showSettings = false
                }
                scheduleHideControls()
            } else {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showControls.toggle()
                }
                scheduleHideControls()
            }
        }
        .focusable()
        .focused($isPlayerFocused)
        .onAppear {
            isPlayerFocused = true
            scheduleHideControls()
            if resumePosition != nil {
                withAnimation(.easeInOut(duration: 0.3)) {
                    showResumePrompt = true
                }
                resumeDismissTask = Task {
                    try? await Task.sleep(nanoseconds: 8_000_000_000)
                    if !Task.isCancelled {
                        await MainActor.run {
                            dismissResumePrompt()
                            if let pos = resumePosition {
                                viewModel.bridge.seek(to: pos)
                            }
                            viewModel.play()
                        }
                    }
                }
            } else if autoplay {
                viewModel.play()
            }
        }
        .onKeyPress(.space) {
            handleKeyAction { viewModel.togglePlayPause() }
            return .handled
        }
        .onKeyPress(.leftArrow, phases: .down) { press in
            if press.modifiers.contains(.shift) {
                handleKeyAction { viewModel.seekRelative(seconds: -30) }
            } else {
                handleKeyAction { viewModel.seekRelative(seconds: -10) }
            }
            return .handled
        }
        .onKeyPress(.rightArrow, phases: .down) { press in
            if press.modifiers.contains(.shift) {
                handleKeyAction { viewModel.seekRelative(seconds: 30) }
            } else {
                handleKeyAction { viewModel.seekRelative(seconds: 10) }
            }
            return .handled
        }
        #if os(macOS)
        .onKeyPress(KeyEquivalent("f")) {
            handleKeyAction { toggleFullScreen() }
            return .handled
        }
        #endif
        .onKeyPress(KeyEquivalent("m")) {
            handleKeyAction { viewModel.toggleMute() }
            return .handled
        }
        .onKeyPress(KeyEquivalent("]")) {
            handleKeyAction { viewModel.cycleSpeedUp() }
            return .handled
        }
        .onKeyPress(KeyEquivalent("[")) {
            handleKeyAction { viewModel.cycleSpeedDown() }
            return .handled
        }
    }

    private func handleKeyAction(_ action: () -> Void) {
        action()
        withAnimation(.easeInOut(duration: 0.2)) {
            showControls = true
        }
        scheduleHideControls()
    }

    #if os(macOS)
    private func toggleFullScreen() {
        NSApp.keyWindow?.toggleFullScreen(nil)
    }
    #endif

    private func dismissResumePrompt() {
        resumeDismissTask?.cancel()
        withAnimation(.easeInOut(duration: 0.3)) {
            showResumePrompt = false
        }
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

    private func scheduleHideControls() {
        hideControlsTask?.cancel()
        guard !showSettings && !viewModel.isHoveringTimeline && !viewModel.isDraggingTimeline else { return }
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
