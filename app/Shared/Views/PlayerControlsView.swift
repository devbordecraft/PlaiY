import SwiftUI
import QuartzCore

// ---------------------------------------------------------------------------
// TimelineSectionView: fully isolated. Only @State drives rebuilds.
// Uses Canvas for the timeline bar — no layout passes on position change.
// Wrapped in its own TimelineView by BottomControlsView for 120Hz updates.
// ---------------------------------------------------------------------------
struct TimelineSectionView: View {
    let transport: PlaybackTransport
    let onHoverChanged: (Bool) -> Void
    let onHoverMoved: (Double) -> Void
    let onDragStarted: () -> Void
    let onDragChanged: (Double) -> Void
    let onDragEnded: () -> Void
    let onTimeText: (Double) -> String

    @State private var isHovering = false
    @State private var isDragging = false
    @State private var hoverX: CGFloat = 0
    @State private var lastHoverTime: CFTimeInterval = 0
    private let minHoverInterval: CFTimeInterval = 1.0 / 120.0

    private var isActive: Bool { isHovering || isDragging }
    private var barHeight: CGFloat { isActive ? 8 : 4 }
    private var cursorSize: CGFloat { isActive ? 14 : 8 }

    var body: some View {
        // Read transport directly — no @State mutation in body.
        // The parent TimelineView drives re-evaluation at display rate.
        let fraction = transport.positionFraction
        let currentPosText = transport.positionText
        let currentDurText = transport.durationText
        let currentThumb = transport.seekPreviewImage

        VStack(spacing: 4) {
            GeometryReader { geo in
                let width = geo.size.width
                let smoothX = width * fraction
                let activeX = isActive ? hoverX : smoothX
                let clampedActiveX = max(0, min(width, activeX))
                let progressX = isActive ? clampedActiveX : smoothX

                // Canvas: single GPU-accelerated layer, no SwiftUI layout passes
                // when displayFraction or hoverX change.
                Canvas { context, size in
                    let midY = size.height / 2.0
                    let bh = barHeight
                    let cs = cursorSize

                    // Background track
                    let bgRect = CGRect(x: 0, y: midY - bh / 2, width: size.width, height: bh)
                    context.fill(Path(roundedRect: bgRect, cornerRadius: bh / 2),
                                 with: .color(.white.opacity(0.3)))

                    // Filled progress
                    let fillW = max(0, progressX)
                    let fillRect = CGRect(x: 0, y: midY - bh / 2, width: fillW, height: bh)
                    context.fill(Path(roundedRect: fillRect, cornerRadius: bh / 2),
                                 with: .color(.white))

                    // Cursor circle
                    let cx = max(cs / 2, min(size.width - cs / 2, progressX))
                    let circleRect = CGRect(x: cx - cs / 2, y: midY - cs / 2, width: cs, height: cs)

                    // Shadow (only when active to save draw cost)
                    if isActive {
                        context.drawLayer { shadow in
                            shadow.addFilter(.shadow(color: .black.opacity(0.4), radius: 3, y: 1))
                            shadow.fill(Path(ellipseIn: circleRect), with: .color(.white))
                        }
                    }

                    context.opacity = isActive ? 1.0 : 0.6
                    context.fill(Path(ellipseIn: circleRect), with: .color(.white))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .animation(.spring(response: 0.2, dampingFraction: 0.75), value: isActive)
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        if !isHovering {
                            withAnimation(.spring(response: 0.2, dampingFraction: 0.75)) {
                                isHovering = true
                            }
                            onHoverChanged(true)
                            lastHoverTime = 0
                        }
                        let now = CACurrentMediaTime()
                        guard now - lastHoverTime >= minHoverInterval else { break }
                        lastHoverTime = now
                        hoverX = max(0, min(width, location.x))
                        onHoverMoved(hoverX / width)
                    case .ended:
                        withAnimation(.spring(response: 0.2, dampingFraction: 0.75)) {
                            isHovering = false
                        }
                        onHoverChanged(false)
                    @unknown default:
                        break
                    }
                }
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let now = CACurrentMediaTime()
                            guard now - lastHoverTime >= minHoverInterval else { return }
                            lastHoverTime = now
                            hoverX = max(0, min(width, value.location.x))
                            if !isDragging {
                                isDragging = true
                                onDragStarted()
                            }
                            onDragChanged(hoverX / width)
                        }
                        .onEnded { value in
                            hoverX = max(0, min(width, value.location.x))
                            onDragChanged(hoverX / width)
                            onDragEnded()
                            isDragging = false
                        }
                )

                if let image = currentThumb, isActive {
                    let thumbWidth: CGFloat = 240
                    let thumbHeight: CGFloat = 135
                    let thumbX = max(thumbWidth / 2 + 8 as CGFloat,
                                    min(width - thumbWidth / 2 - 8 as CGFloat, clampedActiveX))

                    Image(decorative: image, scale: 1.0)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: thumbWidth, height: thumbHeight)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(.white.opacity(0.2), lineWidth: 1)
                        )
                        .shadow(color: .black.opacity(0.5), radius: 8, y: 4)
                        .position(x: thumbX, y: -thumbHeight / 2 - 30)
                        .transition(.opacity)
                }

                if isActive {
                    let tooltipText = onTimeText(hoverX / width)
                    Text(tooltipText)
                        .font(.caption)
                        .fontWeight(.medium)
                        .monospacedDigit()
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .glassEffect(.regular, in: .rect(cornerRadius: 6))
                        .foregroundStyle(.white)
                        .position(x: max(30, min(width - 30, clampedActiveX)),
                                  y: currentThumb != nil ? -10 : -16)
                        .transition(.opacity)
                }
            }
            .frame(height: 24)

            HStack {
                Text(currentPosText)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
                    .monospacedDigit()
                Spacer()
                Text(currentDurText)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
                    .monospacedDigit()
            }
        }
    }
}

// ---------------------------------------------------------------------------
// PlaybackButtonsView: only rebuilds when isPlaying or speed changes.
// No gesture state, no timers. NOT inside any TimelineView.
// ---------------------------------------------------------------------------
struct PlaybackButtonsView: View {
    let isPlaying: Bool
    let isMuted: Bool
    let volume: Float
    let playbackSpeed: Double
    let passthroughActive: Bool
    let bridge: PlayerBridge
    let transport: PlaybackTransport
    let onSeekRelative: (Double) -> Void
    let onTogglePlayPause: () -> Void
    let onToggleMute: () -> Void
    let onSetVolume: (Float) -> Void
    let onSetSpeed: (Double) -> Void

    private func speedLabel(_ speed: Double) -> String {
        if speed == Double(Int(speed)) { return "\(Int(speed))x" }
        return String(format: "%.2gx", speed)
    }

    var body: some View {
        HStack(spacing: 32) {
            Button { onSeekRelative(-10) } label: {
                Image(systemName: "gobackward.10").font(.title2)
            }
            .buttonStyle(PlayerButtonStyle())
            .foregroundStyle(.white)

            Button { onTogglePlayPause() } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.title2)
                    .fontWeight(.semibold)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(LargePlayerButtonStyle())
            .foregroundStyle(.white)

            Button { onSeekRelative(10) } label: {
                Image(systemName: "goforward.10").font(.title2)
            }
            .buttonStyle(PlayerButtonStyle())
            .foregroundStyle(.white)

            VolumeControlView(
                isMuted: isMuted,
                initialVolume: volume,
                passthroughActive: passthroughActive,
                bridge: bridge,
                transport: transport,
                onToggleMute: onToggleMute,
                onSetVolume: onSetVolume
            )

            Menu {
                ForEach(PlayerViewModel.speedPresets, id: \.self) { speed in
                    Button {
                        onSetSpeed(speed)
                    } label: {
                        HStack {
                            Text(speedLabel(speed))
                            if abs(playbackSpeed - speed) < 0.01 {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                Text(speedLabel(playbackSpeed))
                    .font(.caption)
                    .fontWeight(.semibold)
                    .monospacedDigit()
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
        }
    }
}

// ---------------------------------------------------------------------------
// VolumeControlView: local @State for slider — NEVER fires objectWillChange.
// Calls bridge.setVolume() directly for zero-overhead volume changes.
// ---------------------------------------------------------------------------
struct VolumeControlView: View {
    let isMuted: Bool
    let initialVolume: Float
    let passthroughActive: Bool
    let bridge: PlayerBridge
    let transport: PlaybackTransport
    let onToggleMute: () -> Void
    let onSetVolume: (Float) -> Void

    @State private var isHovering = false
    @State private var localVolume: Float = 1.0

    private var speakerIcon: String {
        if isMuted || localVolume <= 0 {
            return "speaker.slash.fill"
        } else if localVolume < 0.33 {
            return "speaker.wave.1.fill"
        } else if localVolume < 0.66 {
            return "speaker.wave.2.fill"
        } else {
            return "speaker.wave.3.fill"
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Button {
                onToggleMute()
            } label: {
                Image(systemName: speakerIcon)
                    .font(.title2)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 28)
            }
            .buttonStyle(PlayerButtonStyle())
            .foregroundStyle(.white)

            Slider(
                value: Binding(
                    get: { Double(localVolume) },
                    set: { newValue in
                        localVolume = Float(newValue)
                        // Direct bridge call only — no @Published, no objectWillChange
                        bridge.setVolume(localVolume)
                    }
                ),
                in: 0...1
            )
            .frame(width: isHovering && !passthroughActive ? 100 : 0)
            .opacity(isHovering && !passthroughActive ? 1 : 0)
            .tint(.white)
        }
        .frame(width: 160, alignment: .leading)
        .onHover { hovering in
            withAnimation(.spring(response: 0.2, dampingFraction: 0.75)) {
                isHovering = hovering
            }
            // Track for auto-hide and sync volume when leaving
            transport.isHoveringVolume = hovering
            if !hovering {
                // Commit final volume to viewModel when hover ends
                onSetVolume(localVolume)
            }
        }
        .onAppear {
            localVolume = initialVolume
        }
        .onChange(of: isMuted) { _ in
            // Sync after mute toggle (which may restore volume)
            localVolume = initialVolume
        }
        .onChange(of: initialVolume) { newValue in
            localVolume = newValue
        }
    }
}
