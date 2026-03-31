import SwiftUI
import QuartzCore

struct TimelineSectionView: View {
    let transport: PlaybackTransport
    let onHoverChanged: (Bool) -> Void
    let onHoverMoved: (Double) -> Void
    let onDragStarted: () -> Void
    let onDragChanged: (Double) -> Void
    let onDragEnded: () -> Void
    let onPreviewText: (Double) -> String
    let onElapsedText: () -> String
    let onRemainingText: () -> String

    @State private var isHovering = false
    @State private var isDragging = false
    @State private var hoverX: CGFloat = 0
    @State private var lastHoverTime: CFTimeInterval = 0

    private let minHoverInterval: CFTimeInterval = 1.0 / 120.0
    private let previewWidth: CGFloat = 248

    private var isActive: Bool { isHovering || isDragging }
    private var barHeight: CGFloat { isActive ? 10 : 6 }
    private var cursorSize: CGFloat { isActive ? 18 : 12 }

    var body: some View {
        let playbackFraction = transport.positionFraction
        let elapsedText = onElapsedText()
        let remainingText = onRemainingText()
        let previewImage = transport.seekPreviewImage

        VStack(spacing: 10) {
            GeometryReader { geo in
                let width = max(geo.size.width, 1)
                let smoothX = width * playbackFraction
                let activeX = isActive ? hoverX : smoothX
                let clampedActiveX = max(0, min(width, activeX))
                let progressX = isActive ? clampedActiveX : smoothX
                let previewFraction = isActive ? Double(clampedActiveX / width) : playbackFraction

                ZStack(alignment: .topLeading) {
                    Canvas { context, size in
                        let midY = size.height / 2.0
                        let bh = barHeight
                        let cs = cursorSize

                        let glowRect = CGRect(x: 0, y: midY - (bh + 8) / 2, width: size.width, height: bh + 8)
                        context.fill(Path(roundedRect: glowRect, cornerRadius: (bh + 8) / 2),
                                     with: .color(.white.opacity(isActive ? 0.08 : 0.03)))

                        let bgRect = CGRect(x: 0, y: midY - bh / 2, width: size.width, height: bh)
                        context.fill(Path(roundedRect: bgRect, cornerRadius: bh / 2),
                                     with: .color(.white.opacity(0.14)))

                        let fillRect = CGRect(x: 0, y: midY - bh / 2, width: max(progressX, 0), height: bh)
                        context.fill(Path(roundedRect: fillRect, cornerRadius: bh / 2),
                                     with: .color(.white.opacity(isActive ? 1.0 : 0.92)))

                        let cx = max(cs / 2, min(size.width - cs / 2, progressX))
                        let thumbRect = CGRect(x: cx - cs / 2, y: midY - cs / 2, width: cs, height: cs)

                        if isActive {
                            context.drawLayer { layer in
                                layer.addFilter(.shadow(color: .white.opacity(0.22), radius: 10))
                                layer.fill(Path(ellipseIn: thumbRect), with: .color(.white.opacity(0.95)))
                            }
                        }

                        context.drawLayer { layer in
                            layer.addFilter(.shadow(color: .black.opacity(0.28), radius: 5, y: 2))
                            layer.fill(Path(ellipseIn: thumbRect), with: .color(.white))
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .animation(.spring(response: 0.22, dampingFraction: 0.82), value: isActive)
                    .contentShape(Rectangle())
                    #if !os(tvOS)
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            if !isHovering {
                                withAnimation(.spring(response: 0.22, dampingFraction: 0.82)) {
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
                            withAnimation(.spring(response: 0.22, dampingFraction: 0.82)) {
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
                    #endif

                    if isActive {
                        let previewX = max(previewWidth / 2, min(width - previewWidth / 2, clampedActiveX))
                        TimelinePreviewCard(
                            image: previewImage,
                            timeText: onPreviewText(previewFraction)
                        )
                        .position(x: previewX, y: -86)
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    }
                }
            }
            .frame(height: 34)

            HStack {
                Text(elapsedText)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.84))
                    .monospacedDigit()
                Spacer()
                Text(remainingText)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.72))
                    .monospacedDigit()
            }
        }
    }
}

private struct TimelinePreviewCard: View {
    let image: CGImage?
    let timeText: String

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.black.opacity(0.3))
                    .frame(width: 248, height: 140)

                if let image {
                    Image(decorative: image, scale: 1.0)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 248, height: 140)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "film.stack.fill")
                            .font(.title3.weight(.semibold))
                        Text("Preview")
                            .font(.caption2.weight(.medium))
                    }
                    .foregroundStyle(.white.opacity(0.7))
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(.white.opacity(0.14), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.35), radius: 18, y: 10)

            Text(timeText)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .monospacedDigit()
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background {
                    ZStack {
                        Capsule()
                            .fill(Color(red: 0.07, green: 0.08, blue: 0.1).opacity(0.92))
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [
                                        .white.opacity(0.12),
                                        .white.opacity(0.03),
                                        .black.opacity(0.16)
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                    }
                }
                .overlay(
                    Capsule()
                        .stroke(.white.opacity(0.12), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.28), radius: 10, y: 5)
        }
    }
}

struct PlaybackButtonsView: View {
    let isPlaying: Bool
    let isMuted: Bool
    let volume: Float
    let playbackSpeed: Double
    let passthroughActive: Bool
    let bridge: PlayerBridge
    let transport: PlaybackTransport
    let showSettings: Bool
    let onPreviousTrack: (() -> Void)?
    let onNextTrack: (() -> Void)?
    let onSeekRelative: (Double) -> Void
    let onTogglePlayPause: () -> Void
    let onToggleMute: () -> Void
    let onSetVolume: (Float) -> Void
    let onSetSpeed: (Double) -> Void
    let onToggleSettings: () -> Void
    let onToggleFullScreen: (() -> Void)?

    private func speedLabel(_ speed: Double) -> String {
        if speed == Double(Int(speed)) { return "\(Int(speed))x" }
        return String(format: "%.2gx", speed)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 20) {
            VolumeControlView(
                isMuted: isMuted,
                initialVolume: volume,
                passthroughActive: passthroughActive,
                bridge: bridge,
                transport: transport,
                onToggleMute: onToggleMute,
                onSetVolume: onSetVolume
            )
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 14) {
                if let onPreviousTrack {
                    Button(action: onPreviousTrack) {
                        Image(systemName: "backward.end.fill")
                            .font(.title3.weight(.semibold))
                    }
                    .buttonStyle(PlayerButtonStyle())
                    .foregroundStyle(.white)
                }

                Button { onSeekRelative(-10) } label: {
                    Image(systemName: "gobackward.10")
                        .font(.title2.weight(.semibold))
                }
                .buttonStyle(PlayerButtonStyle())
                .foregroundStyle(.white)

                Button { onTogglePlayPause() } label: {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2.weight(.semibold))
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(LargePlayerButtonStyle())
                .foregroundStyle(.white)

                Button { onSeekRelative(10) } label: {
                    Image(systemName: "goforward.10")
                        .font(.title2.weight(.semibold))
                }
                .buttonStyle(PlayerButtonStyle())
                .foregroundStyle(.white)

                if let onNextTrack {
                    Button(action: onNextTrack) {
                        Image(systemName: "forward.end.fill")
                            .font(.title3.weight(.semibold))
                    }
                    .buttonStyle(PlayerButtonStyle())
                    .foregroundStyle(.white)
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)

            HStack(spacing: 12) {
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
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background {
                            ZStack {
                                Capsule()
                                    .fill(Color(red: 0.08, green: 0.09, blue: 0.11).opacity(0.88))
                                Capsule()
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
                            Capsule()
                                .stroke(.white.opacity(0.1), lineWidth: 1)
                        )
                        .shadow(color: .black.opacity(0.22), radius: 8, y: 4)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)

                Button(action: onToggleSettings) {
                    Image(systemName: "gearshape")
                        .font(.title3.weight(.semibold))
                }
                .buttonStyle(PlayerButtonStyle())
                .foregroundStyle(showSettings ? .white.opacity(0.95) : .white)

                if let onToggleFullScreen {
                    Button(action: onToggleFullScreen) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.title3.weight(.semibold))
                    }
                    .buttonStyle(PlayerButtonStyle())
                    .foregroundStyle(.white)
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}

struct VolumeControlView: View {
    let isMuted: Bool
    let initialVolume: Float
    let passthroughActive: Bool
    let bridge: PlayerBridge
    let transport: PlaybackTransport
    let onToggleMute: () -> Void
    let onSetVolume: (Float) -> Void

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
        HStack(spacing: 10) {
            Button(action: onToggleMute) {
                Image(systemName: speakerIcon)
                    .font(.title3.weight(.semibold))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 24)
            }
            .buttonStyle(PlayerButtonStyle())
            .foregroundStyle(.white)

            #if !os(tvOS)
            Slider(
                value: Binding(
                    get: { Double(localVolume) },
                    set: { newValue in
                        localVolume = Float(newValue)
                        bridge.setVolume(localVolume)
                    }
                ),
                in: 0...1,
                onEditingChanged: { editing in
                    transport.isHoveringVolume = editing
                    if !editing {
                        onSetVolume(localVolume)
                    }
                }
            )
            .frame(width: 108)
            .tint(.white)
            .labelsHidden()
            .disabled(passthroughActive)
            .opacity(passthroughActive ? 0.45 : 1.0)
            #endif
        }
        .onAppear {
            localVolume = initialVolume
        }
        .onChange(of: isMuted) { _ in
            localVolume = initialVolume
        }
        .onChange(of: initialVolume) { newValue in
            localVolume = newValue
        }
    }
}
