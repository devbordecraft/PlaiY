import SwiftUI

struct PlayerView: View {
    @ObservedObject var viewModel: PlayerViewModel
    let onBack: () -> Void

    @State private var showControls = true
    @State private var showSettings = false
    @State private var hideControlsTask: Task<Void, Never>?
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
