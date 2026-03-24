import SwiftUI
import QuartzCore

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
    @State private var zoomBase: Double = 1.0
    @State private var panBase: (x: Double, y: Double) = (0, 0)
    #if os(macOS)
    @State private var scrollMonitor: Any?
    #endif
    @FocusState private var isPlayerFocused: Bool

    var body: some View {
        ZStack {
            // Video layer
            MetalPlayerView(playerBridge: viewModel.bridge, transport: viewModel.transport)
                .ignoresSafeArea()
                .gesture(
                    DragGesture(minimumDistance: 10)
                        .onChanged { value in
                            guard viewModel.transport.displaySettings.zoom > 1.001 else { return }
                            let dx = value.translation.width / 200.0
                            let dy = value.translation.height / 200.0
                            viewModel.setPan(x: panBase.x + dx, y: panBase.y + dy)
                        }
                        .onEnded { _ in
                            panBase = (viewModel.transport.displaySettings.panX,
                                       viewModel.transport.displaySettings.panY)
                        }
                )

            // ── Display-link tick + subtitle ──
            // Lightweight TimelineView: only runs tick() and subtitle overlay.
            // Buttons, menus, gradients are NOT inside — they don't re-evaluate
            // at 120Hz, only on @Published changes.
            TimelineView(.animation(minimumInterval: nil, paused: !viewModel.isPlaying)) { _ in
                let _ = viewModel.tick()
                SubtitleOverlayView(transport: viewModel.transport)
            }
            .allowsHitTesting(false)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // ── Controls overlay ──
            // NOT inside TimelineView — only rebuilt on @Published / @State changes.
            // .drawingGroup() rasterizes the entire overlay into a single Metal
            // texture, so the WindowServer composites 1 layer over the video
            // instead of ~20 individual CA layers.
            if showControls {
                VStack {
                    TopBarView(
                        mediaTitle: viewModel.mediaTitle,
                        showDebugOverlay: viewModel.showDebugOverlay,
                        onBack: onBack,
                        onToggleFullScreen: { toggleFullScreen() },
                        onToggleDebug: { viewModel.showDebugOverlay.toggle() },
                        onToggleSettings: {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                                showSettings.toggle()
                            }
                            if showSettings {
                                hideControlsTask?.cancel()
                            } else {
                                scheduleHideControls()
                            }
                        }
                    )

                    Spacer()

                    // Bottom controls: timeline (120Hz) + buttons (static)
                    BottomControlsView(
                        viewModel: viewModel,
                        onSeekRelative: { viewModel.seekRelative(seconds: $0) },
                        onTogglePlayPause: { viewModel.togglePlayPause() },
                        onToggleMute: { viewModel.toggleMute() },
                        onSetVolume: { viewModel.setVolume($0) },
                        onSetSpeed: { viewModel.setPlaybackSpeed($0) },
                        onTimelineHoverChanged: { viewModel.timelineHoverChanged($0) },
                        onTimelineHoverMoved: { viewModel.timelineHoverMoved(fraction: $0) },
                        onTimelineDragStarted: { viewModel.timelineDragStarted() },
                        onTimelineDragChanged: { viewModel.timelineDragChanged(fraction: $0) },
                        onTimelineDragEnded: { viewModel.timelineDragEnded() },
                        onTimeText: { viewModel.timeText(for: $0) }
                    )
                }
                .compositingGroup()
            }

            // Debug overlay (top-left, always visible when toggled)
            if viewModel.showDebugOverlay {
                DebugOverlayWrapper(bridge: viewModel.bridge)
            }

            // Settings panel overlay
            if showSettings {
                TrackSelectionView(
                    viewModel: viewModel,
                    isPresented: $showSettings
                )
            }

            // Resume prompt overlay (outside drawingGroup — uses .ultraThinMaterial)
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
                withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                    showSettings = false
                }
                scheduleHideControls()
            } else {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                    showControls.toggle()
                }
                scheduleHideControls()
            }
        }
        .focusable()
        .focused($isPlayerFocused)
        .focusEffectDisabled()
        .onAppear {
            isPlayerFocused = true
            scheduleHideControls()
            #if os(macOS)
            scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [self] event in
                guard event.modifierFlags.contains(.option) else { return event }
                viewModel.adjustZoom(by: event.scrollingDeltaY * 0.02)
                return nil
            }
            #endif
            if resumePosition != nil {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
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
        .onKeyPress(.upArrow, phases: .down) { _ in
            handleKeyAction { viewModel.setVolume(viewModel.volume + 0.05) }
            return .handled
        }
        .onKeyPress(.downArrow, phases: .down) { _ in
            handleKeyAction { viewModel.setVolume(viewModel.volume - 0.05) }
            return .handled
        }
        .onKeyPress(KeyEquivalent("=")) {
            handleKeyAction { viewModel.adjustZoom(by: 0.25) }
            return .handled
        }
        .onKeyPress(KeyEquivalent("-")) {
            handleKeyAction { viewModel.adjustZoom(by: -0.25) }
            return .handled
        }
        .onKeyPress(KeyEquivalent("0")) {
            handleKeyAction { viewModel.resetDisplaySettings() }
            return .handled
        }
        .gesture(
            MagnifyGesture()
                .onChanged { value in
                    viewModel.setZoom(zoomBase * value.magnification)
                }
                .onEnded { _ in
                    zoomBase = viewModel.transport.displaySettings.zoom
                }
        )
        #if os(macOS)
        .onDisappear {
            if let monitor = scrollMonitor {
                NSEvent.removeMonitor(monitor)
                scrollMonitor = nil
            }
        }
        #endif
    }

    private func handleKeyAction(_ action: () -> Void) {
        action()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
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
        withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
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
        guard !showSettings else { return }
        hideControlsTask = Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000) // 4 seconds
            if !Task.isCancelled {
                await MainActor.run {
                    // Don't hide while user is interacting — reschedule instead
                    if showSettings || viewModel.transport.isUserInteracting {
                        scheduleHideControls()
                        return
                    }
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                        showControls = false
                    }
                }
            }
        }
    }
}

// ---------------------------------------------------------------------------
// TopBarView: extracted so SwiftUI can skip its body when inputs don't change.
// NOT inside any TimelineView — never re-evaluated at 120Hz.
// ---------------------------------------------------------------------------
private struct TopBarView: View {
    let mediaTitle: String
    let showDebugOverlay: Bool
    let onBack: () -> Void
    let onToggleFullScreen: () -> Void
    let onToggleDebug: () -> Void
    let onToggleSettings: () -> Void

    var body: some View {
        HStack {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.title2)
                    .fontWeight(.semibold)
            }
            .buttonStyle(PlayerButtonStyle())
            .foregroundStyle(.white)

            Text(mediaTitle)
                .font(.headline)
                .foregroundStyle(.white)

            Spacer()

            #if os(macOS)
            Button(action: onToggleFullScreen) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.title2)
                    .fontWeight(.semibold)
            }
            .buttonStyle(PlayerButtonStyle())
            .foregroundStyle(.white)
            #endif

            Button(action: onToggleDebug) {
                Image(systemName: "ant")
                    .font(.title2)
                    .fontWeight(.semibold)
            }
            .buttonStyle(PlayerButtonStyle())
            .foregroundStyle(showDebugOverlay ? .green : .white)

            Button(action: onToggleSettings) {
                Image(systemName: "gearshape")
                    .font(.title2)
                    .fontWeight(.semibold)
            }
            .buttonStyle(PlayerButtonStyle())
            .foregroundStyle(.white)
        }
        .padding()
        .background(
            LinearGradient(colors: [.black.opacity(0.6), .clear],
                           startPoint: .top, endPoint: .bottom)
        )
    }
}

// ---------------------------------------------------------------------------
// BottomControlsView: wraps timeline + buttons. The timeline gets its own
// TimelineView for 120Hz updates; buttons are static and never re-evaluate
// at display rate.
// ---------------------------------------------------------------------------
private struct BottomControlsView: View {
    let viewModel: PlayerViewModel
    let onSeekRelative: (Double) -> Void
    let onTogglePlayPause: () -> Void
    let onToggleMute: () -> Void
    let onSetVolume: (Float) -> Void
    let onSetSpeed: (Double) -> Void
    let onTimelineHoverChanged: (Bool) -> Void
    let onTimelineHoverMoved: (Double) -> Void
    let onTimelineDragStarted: () -> Void
    let onTimelineDragChanged: (Double) -> Void
    let onTimelineDragEnded: () -> Void
    let onTimeText: (Double) -> String

    var body: some View {
        VStack(spacing: 12) {
            // Timeline: its own TimelineView for 120Hz Canvas updates
            TimelineView(.animation(minimumInterval: nil, paused: !viewModel.isPlaying)) { _ in
                TimelineSectionView(
                    transport: viewModel.transport,
                    onHoverChanged: onTimelineHoverChanged,
                    onHoverMoved: onTimelineHoverMoved,
                    onDragStarted: onTimelineDragStarted,
                    onDragChanged: onTimelineDragChanged,
                    onDragEnded: onTimelineDragEnded,
                    onTimeText: onTimeText
                )
            }

            // Buttons: static, NOT in TimelineView
            PlaybackButtonsView(
                isPlaying: viewModel.isPlaying,
                isMuted: viewModel.isMuted,
                volume: viewModel.volume,
                playbackSpeed: viewModel.playbackSpeed,
                passthroughActive: viewModel.transport.passthroughActive,
                bridge: viewModel.bridge,
                transport: viewModel.transport,
                onSeekRelative: onSeekRelative,
                onTogglePlayPause: onTogglePlayPause,
                onToggleMute: onToggleMute,
                onSetVolume: onSetVolume,
                onSetSpeed: onSetSpeed
            )
        }
        .padding(.horizontal)
        .padding(.bottom, 20)
        .background(
            LinearGradient(colors: [.clear, .black.opacity(0.7)],
                           startPoint: .top, endPoint: .bottom)
        )
    }
}

struct DebugOverlayWrapper: View {
    let bridge: PlayerBridge
    @State private var stats: PYPlaybackStats?
    @State private var timer: Timer?

    var body: some View {
        VStack {
            HStack {
                if let stats {
                    DebugOverlayView(stats: stats)
                        .padding(8)
                }
                Spacer()
            }
            Spacer()
        }
        .allowsHitTesting(false)
        .onAppear {
            stats = bridge.getPlaybackStats()
            timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
                stats = bridge.getPlaybackStats()
            }
        }
        .onDisappear {
            timer?.invalidate()
            timer = nil
        }
    }
}

struct PlayerButtonStyle: ButtonStyle {
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.85 : isHovering ? 1.1 : 1.0)
            .opacity(configuration.isPressed ? 0.7 : 1.0)
            .animation(.spring(response: 0.15, dampingFraction: 0.7), value: configuration.isPressed)
            .animation(.spring(response: 0.2, dampingFraction: 0.75), value: isHovering)
            .onHover { isHovering = $0 }
    }
}
