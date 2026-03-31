import SwiftUI
import QuartzCore

struct PlayerView: View {
    @ObservedObject var viewModel: PlayerViewModel
    @ObservedObject var playQueue: PlayQueue
    let resumePosition: Int64?
    let onBack: () -> Void
    var onNextTrack: (() -> Void)?
    var onPreviousTrack: (() -> Void)?
    var onJumpToQueueItem: ((Int) -> Void)?

    @State private var showControls = true
    @State private var showSettings = false
    @State private var showQueue = false
    @State private var showResumePrompt = false
    @State private var hideControlsTask: Task<Void, Never>?
    @State private var resumeDismissTask: Task<Void, Never>?
    @State private var zoomBase: Double = 1.0
    @State private var panBase: (x: Double, y: Double) = (0, 0)
    #if os(macOS)
    @State private var scrollMonitor: Any?
    #endif
    #if os(tvOS)
    enum PlayerFocus: Hashable { case video, controls }
    @FocusState private var playerFocus: PlayerFocus?
    #else
    @FocusState private var isPlayerFocused: Bool
    #endif

    var body: some View {
        ZStack {
            // Video layer
            if viewModel.isDolbyVision {
                DVDisplayLayerView(playerBridge: viewModel.playerBridge)
                    .ignoresSafeArea()
            } else {
                MetalPlayerView(playerBridge: viewModel.playerBridge, transport: viewModel.transport)
                    .ignoresSafeArea()
            }

            // ── Display-link tick + subtitle ──
            // Lightweight TimelineView: only runs tick() and subtitle overlay.
            // Buttons, menus, gradients are NOT inside — they don't re-evaluate
            // at 120Hz, only on @Published changes.
            TimelineView(.animation(minimumInterval: nil, paused: !viewModel.isPlaying)) { _ in
                let _ = viewModel.tick()
                SubtitleOverlayView(subtitle: viewModel.transport.currentSubtitle,
                                    isHDRContent: viewModel.transport.isHDRContent,
                                    videoWidth: viewModel.transport.videoWidth,
                                    videoHeight: viewModel.transport.videoHeight,
                                    videoSARNum: viewModel.transport.videoSARNum,
                                    videoSARDen: viewModel.transport.videoSARDen,
                                    displaySettings: viewModel.transport.displaySettings)
            }
            .allowsHitTesting(false)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // ── Tap/drag target for video area ──
            // Sits behind controls but above video. Handles tap-to-toggle
            // and pan drag (moved from MetalPlayerView so it receives hit tests).
            Color.clear
                .contentShape(Rectangle())
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
                        if showControls { scheduleHideControls() }
                    }
                }
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

            // ── tvOS Siri Remote gesture layer ──
            #if os(tvOS)
            TVRemoteGestureView(
                onSwipeSeek: { seconds in
                    handleKeyAction { viewModel.seekRelative(seconds: seconds) }
                },
                onTap: {
                    if showControls {
                        handleKeyAction { viewModel.togglePlayPause() }
                    } else {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                            showControls = true
                        }
                        scheduleHideControls()
                    }
                }
            )
            .ignoresSafeArea()
            .allowsHitTesting(!showControls)
            #endif

            // ── Controls overlay ──
            // Always in view tree; visibility via opacity preserves hover state.
            VStack {
                TopBarView(
                    mediaTitle: viewModel.mediaTitle,
                    showDebugOverlay: viewModel.showDebugOverlay,
                    queueItemCount: playQueue.items.count,
                    onBack: onBack,
                    onToggleDebug: { viewModel.showDebugOverlay.toggle() },
                    onToggleQueue: {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                            showQueue.toggle()
                            if showQueue { showSettings = false }
                        }
                        if showQueue {
                            hideControlsTask?.cancel()
                        } else {
                            scheduleHideControls()
                        }
                    }
                )
                #if !os(tvOS)
                .onHover { hovering in
                    viewModel.transport.isHoveringControls = hovering
                    if !hovering { scheduleHideControls() }
                }
                #endif

                Spacer()

                // Bottom controls: timeline (120Hz) + buttons (static)
                BottomControlsView(
                    viewModel: viewModel,
                    onSeekRelative: { viewModel.seekRelative(seconds: $0) },
                    onTogglePlayPause: { viewModel.togglePlayPause() },
                    onToggleMute: { viewModel.toggleMute() },
                    onSetVolume: { viewModel.setVolume($0) },
                    onSetSpeed: { viewModel.setPlaybackSpeed($0) },
                    showSettings: showSettings,
                    onPreviousTrack: onPreviousTrack,
                    onNextTrack: onNextTrack,
                    onToggleSettings: { toggleSettingsPanel() },
                    onToggleFullScreen: fullScreenAction(),
                    onTimelineHoverChanged: { viewModel.timelineHoverChanged($0) },
                    onTimelineHoverMoved: { viewModel.timelineHoverMoved(fraction: $0) },
                    onTimelineDragStarted: { viewModel.timelineDragStarted() },
                    onTimelineDragChanged: { viewModel.timelineDragChanged(fraction: $0) },
                    onTimelineDragEnded: { viewModel.timelineDragEnded() },
                    onPreviewText: { viewModel.timeText(for: $0) },
                    onElapsedText: { viewModel.timelineElapsedText() },
                    onRemainingText: { viewModel.timelineRemainingText() }
                )
                #if !os(tvOS)
                .onHover { hovering in
                    viewModel.transport.isHoveringControls = hovering
                    if !hovering { scheduleHideControls() }
                }
                #endif
            }
            .opacity(showControls ? 1 : 0)
            .allowsHitTesting(showControls)
            .animation(.spring(response: 0.35, dampingFraction: 0.82), value: showControls)

            // Debug overlay (top-left, always visible when toggled)
            if viewModel.showDebugOverlay {
                DebugOverlayWrapper(bridge: viewModel.playerBridge)
            }

            // Settings panel overlay
            if showSettings {
                TrackSelectionView(
                    viewModel: viewModel,
                    isPresented: $showSettings
                )
            }

            // Queue panel overlay
            if showQueue {
                PlayQueueView(
                    queue: playQueue,
                    isPresented: $showQueue,
                    onJumpTo: { index in
                        guard index != playQueue.currentIndex else { return }
                        onJumpToQueueItem?(index)
                    }
                )
            }

            if viewModel.showSkipIntro {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Button {
                            handleKeyAction { viewModel.skipIntro() }
                        } label: {
                            Label("Skip Intro", systemImage: "forward.end.fill")
                                .fontWeight(.semibold)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 12)
                        }
                        .buttonStyle(.borderedProminent)
                        .padding(.trailing, 28)
                        .padding(.bottom, showControls ? 190 : 110)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .trailing)))
            }

            // Resume prompt overlay
            if showResumePrompt, let pos = resumePosition {
                ResumePromptView(position: pos, onResume: {
                    dismissResumePrompt()
                    viewModel.seek(toMicroseconds: pos)
                    viewModel.play()
                }, onStartOver: {
                    dismissResumePrompt()
                    viewModel.play()
                })
            }
        }
        .background(.black)
        #if !os(tvOS)
        .onContinuousHover { phase in
            switch phase {
            case .active:
                if !showControls {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                        showControls = true
                    }
                }
                scheduleHideControls()
            case .ended:
                scheduleHideControls()
            @unknown default:
                break
            }
        }
        #endif
        .focusable()
        #if os(tvOS)
        .focused($playerFocus, equals: .video)
        #else
        .focused($isPlayerFocused)
        #endif
        .focusEffectDisabled()
        .onAppear {
            #if os(tvOS)
            playerFocus = .video
            #else
            isPlayerFocused = true
            #endif
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
                                viewModel.seek(toMicroseconds: pos)
                            }
                            viewModel.play()
                        }
                    }
                }
            }
        }
        #if os(tvOS)
        .onPlayPauseCommand {
            if showControls {
                handleKeyAction { viewModel.togglePlayPause() }
            } else {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                    showControls = true
                }
                scheduleHideControls()
            }
        }
        .onMoveCommand { direction in
            switch direction {
            case .left:
                handleKeyAction { viewModel.seekRelative(seconds: -10) }
            case .right:
                handleKeyAction { viewModel.seekRelative(seconds: 10) }
            case .up:
                handleKeyAction { viewModel.setVolume(min(viewModel.volume + 0.05, 1.0)) }
            case .down:
                handleKeyAction { viewModel.setVolume(max(viewModel.volume - 0.05, 0.0)) }
            @unknown default:
                break
            }
        }
        .onExitCommand {
            if showSettings {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                    showSettings = false
                }
                scheduleHideControls()
            } else if showControls {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                    showControls = false
                }
            } else {
                onBack()
            }
        }
        .onChange(of: showControls) { visible in
            playerFocus = visible ? .controls : .video
        }
        #else
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
        .onKeyPress(KeyEquivalent("n")) {
            if let next = onNextTrack {
                handleKeyAction { next() }
                return .handled
            }
            return .ignored
        }
        .onKeyPress(KeyEquivalent("p")) {
            if let prev = onPreviousTrack {
                handleKeyAction { prev() }
                return .handled
            }
            return .ignored
        }
        .onKeyPress(KeyEquivalent("l")) {
            handleKeyAction {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                    showQueue.toggle()
                    if showQueue { showSettings = false }
                }
            }
            return .handled
        }
        #endif
        .gesture(
            MagnifyGesture()
                .onChanged { value in
                    viewModel.setZoom(zoomBase * value.magnification)
                }
                .onEnded { _ in
                    zoomBase = viewModel.transport.displaySettings.zoom
                }
        )
        .alert("Open Error", isPresented: Binding(
            get: { viewModel.openError != nil },
            set: { if !$0 { viewModel.openError = nil } }
        )) {
            Button("OK") { onBack() }
        } message: {
            Text(viewModel.openError ?? "")
        }
        #if os(macOS)
        .onDisappear {
            if let monitor = scrollMonitor {
                NSEvent.removeMonitor(monitor)
                scrollMonitor = nil
            }
        }
        #endif
        #if os(iOS)
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
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

    private func toggleSettingsPanel() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
            showSettings.toggle()
            if showSettings { showQueue = false }
        }
        if showSettings {
            hideControlsTask?.cancel()
        } else {
            scheduleHideControls()
        }
    }

    private func fullScreenAction() -> (() -> Void)? {
        #if os(macOS)
        return { toggleFullScreen() }
        #else
        return nil
        #endif
    }

    private func scheduleHideControls() {
        hideControlsTask?.cancel()
        guard !showSettings else { return }
        hideControlsTask = Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000) // 4 seconds
            if !Task.isCancelled {
                await MainActor.run {
                    // Don't hide while user is interacting — hover-end handlers
                    // will call scheduleHideControls() when interaction ends.
                    guard !showSettings && !viewModel.transport.isUserInteracting else {
                        return
                    }
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                        showControls = false
                    }
                    #if os(macOS)
                    NSCursor.setHiddenUntilMouseMoves(true)
                    #endif
                }
            }
        }
    }
}

// ---------------------------------------------------------------------------
// ResumePromptView: resume/start-over overlay shown when a file has a saved position.
// ---------------------------------------------------------------------------
private struct ResumePromptView: View {
    let position: Int64
    let onResume: () -> Void
    let onStartOver: () -> Void

    var body: some View {
        VStack {
            Spacer()
            HStack(spacing: 16) {
                Button {
                    onResume()
                } label: {
                    Label("Resume from \(TimeFormatting.display(position))", systemImage: "play.fill")
                        .fontWeight(.semibold)
                }
                .buttonStyle(.borderedProminent)

                Button {
                    onStartOver()
                } label: {
                    Text("Start from Beginning")
                }
                .buttonStyle(.bordered)
            }
            .font(.callout)
            .foregroundStyle(.white)
            .padding(20)
            .glassEffect(.regular, in: .rect(cornerRadius: 14))
            .padding(.bottom, 100)
        }
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }
}

// ---------------------------------------------------------------------------
// TopBarView: extracted so SwiftUI can skip its body when inputs don't change.
// NOT inside any TimelineView — never re-evaluated at 120Hz.
// ---------------------------------------------------------------------------
private struct TopBarView: View {
    let mediaTitle: String
    let showDebugOverlay: Bool
    let queueItemCount: Int
    let onBack: () -> Void
    let onToggleDebug: () -> Void
    let onToggleQueue: () -> Void

    var body: some View {
        GlassEffectContainer {
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

                if queueItemCount > 1 {
                    Button(action: onToggleQueue) {
                        Image(systemName: "list.bullet")
                            .font(.title2)
                            .fontWeight(.semibold)
                    }
                    .buttonStyle(PlayerButtonStyle())
                    .foregroundStyle(.white)
                }

                Button(action: onToggleDebug) {
                    Image(systemName: "ant")
                        .font(.title2)
                        .fontWeight(.semibold)
                }
                .buttonStyle(PlayerButtonStyle())
                .foregroundStyle(showDebugOverlay ? .green : .white)
            }
            .padding()
        }
        .background(
            LinearGradient(colors: [.black.opacity(0.6), .clear],
                           startPoint: .top, endPoint: .bottom)
        )
        .contentShape(Rectangle())
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
    let showSettings: Bool
    let onPreviousTrack: (() -> Void)?
    let onNextTrack: (() -> Void)?
    let onToggleSettings: () -> Void
    let onToggleFullScreen: (() -> Void)?
    let onTimelineHoverChanged: (Bool) -> Void
    let onTimelineHoverMoved: (Double) -> Void
    let onTimelineDragStarted: () -> Void
    let onTimelineDragChanged: (Double) -> Void
    let onTimelineDragEnded: () -> Void
    let onPreviewText: (Double) -> String
    let onElapsedText: () -> String
    let onRemainingText: () -> String

    var body: some View {
        HStack {
            Spacer(minLength: 0)
            GlassEffectContainer {
                VStack(spacing: 16) {
                    PlaybackButtonsView(
                        isPlaying: viewModel.isPlaying,
                        isMuted: viewModel.isMuted,
                        volume: viewModel.volume,
                        playbackSpeed: viewModel.playbackSpeed,
                        passthroughActive: viewModel.transport.passthroughActive,
                        bridge: viewModel.playerBridge,
                        transport: viewModel.transport,
                        showSettings: showSettings,
                        onPreviousTrack: onPreviousTrack,
                        onNextTrack: onNextTrack,
                        onSeekRelative: onSeekRelative,
                        onTogglePlayPause: onTogglePlayPause,
                        onToggleMute: onToggleMute,
                        onSetVolume: onSetVolume,
                        onSetSpeed: onSetSpeed,
                        onToggleSettings: onToggleSettings,
                        onToggleFullScreen: onToggleFullScreen
                    )

                    TimelineView(.animation(minimumInterval: nil, paused: !viewModel.isPlaying)) { _ in
                        TimelineSectionView(
                            transport: viewModel.transport,
                            onHoverChanged: onTimelineHoverChanged,
                            onHoverMoved: onTimelineHoverMoved,
                            onDragStarted: onTimelineDragStarted,
                            onDragChanged: onTimelineDragChanged,
                            onDragEnded: onTimelineDragEnded,
                            onPreviewText: onPreviewText,
                            onElapsedText: onElapsedText,
                            onRemainingText: onRemainingText
                        )
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 18)
                .frame(maxWidth: 860)
                .background {
                    RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .fill(Color(red: 0.06, green: 0.07, blue: 0.09).opacity(0.9))
                    RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    .white.opacity(0.12),
                                    .white.opacity(0.03),
                                    .black.opacity(0.18)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                    RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color(red: 0.32, green: 0.34, blue: 0.38).opacity(0.18),
                                    .clear,
                                    .black.opacity(0.2)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .stroke(.white.opacity(0.12), lineWidth: 1)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .stroke(
                            LinearGradient(
                                colors: [
                                    .white.opacity(0.22),
                                    .white.opacity(0.04),
                                    .clear
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 1
                        )
                )
                .shadow(color: .black.opacity(0.4), radius: 28, y: 16)
            }
            Spacer(minLength: 0)
        }
        .background {
            Ellipse()
                .fill(.black.opacity(0.26))
                .frame(width: 1200, height: 250)
                .blur(radius: 80)
                .offset(y: 54)
                .allowsHitTesting(false)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 28)
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
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(8)
            .background {
                ZStack {
                    Circle()
                        .fill(Color(red: 0.08, green: 0.09, blue: 0.11).opacity(configuration.isPressed ? 0.96 : 0.88))
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [
                                    .white.opacity(0.12),
                                    .white.opacity(0.03),
                                    .black.opacity(0.14)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                }
            }
            .overlay(
                Circle()
                    .stroke(.white.opacity(0.1), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.22), radius: 8, y: 4)
            .scaleEffect(configuration.isPressed ? 0.9 : 1.0)
            .animation(.spring(response: 0.15, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

struct LargePlayerButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(12)
            .background {
                ZStack {
                    Circle()
                        .fill(Color(red: 0.08, green: 0.09, blue: 0.11).opacity(configuration.isPressed ? 0.98 : 0.9))
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [
                                    .white.opacity(0.14),
                                    .white.opacity(0.04),
                                    .black.opacity(0.16)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                }
            }
            .overlay(
                Circle()
                    .stroke(.white.opacity(0.11), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.24), radius: 10, y: 5)
            .scaleEffect(configuration.isPressed ? 0.9 : 1.0)
            .animation(.spring(response: 0.15, dampingFraction: 0.7), value: configuration.isPressed)
    }
}
