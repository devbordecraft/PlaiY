import SwiftUI
import QuartzCore

struct PlayerControlsView: View {
    @ObservedObject var viewModel: PlayerViewModel

    @State private var isHovering = false
    @State private var isDragging = false
    @State private var hoverX: CGFloat = 0
    @State private var lastHoverTime: CFTimeInterval = 0
    private let minHoverInterval: CFTimeInterval = 1.0 / 120.0

    private var isActive: Bool {
        isHovering || isDragging
    }

    private var barHeight: CGFloat {
        isActive ? 8 : 4
    }

    private var cursorSize: CGFloat {
        isActive ? 14 : 8
    }

    var body: some View {
        VStack(spacing: 12) {
            // Timeline section
            VStack(spacing: 4) {
                GeometryReader { geo in
                    let width = geo.size.width
                    let progressX = width * viewModel.positionFraction
                    let activeX = isActive ? hoverX : progressX
                    let clampedActiveX = max(0, min(width, activeX))

                    ZStack(alignment: .leading) {
                        // Background track
                        Capsule()
                            .fill(.white.opacity(0.3))
                            .frame(height: barHeight)

                        // Played progress
                        Capsule()
                            .fill(.white)
                            .frame(width: max(0, isActive ? clampedActiveX : progressX),
                                   height: barHeight)

                        // Circle cursor
                        Circle()
                            .fill(.white)
                            .frame(width: cursorSize, height: cursorSize)
                            .shadow(color: .black.opacity(0.4), radius: 3, y: 1)
                            .opacity(isActive ? 1 : 0.6)
                            .position(x: max(cursorSize / 2,
                                           min(width - cursorSize / 2,
                                               isActive ? clampedActiveX : progressX)),
                                      y: geo.size.height / 2)
                    }
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            if !isHovering {
                                withAnimation(.easeInOut(duration: 0.15)) { isHovering = true }
                                viewModel.timelineHoverChanged(true)
                                lastHoverTime = 0
                            }
                            let now = CACurrentMediaTime()
                            guard now - lastHoverTime >= minHoverInterval else { break }
                            lastHoverTime = now
                            hoverX = max(0, min(width, location.x))
                            viewModel.timelineHoverMoved(fraction: hoverX / width)
                        case .ended:
                            withAnimation(.easeInOut(duration: 0.15)) { isHovering = false }
                            viewModel.timelineHoverChanged(false)
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
                                    viewModel.timelineDragStarted()
                                }
                                viewModel.timelineDragChanged(fraction: hoverX / width)
                            }
                            .onEnded { value in
                                hoverX = max(0, min(width, value.location.x))
                                viewModel.timelineDragChanged(fraction: hoverX / width)
                                viewModel.timelineDragEnded()
                                isDragging = false
                            }
                    )

                    // Seek preview thumbnail
                    if let image = viewModel.seekPreviewImage, isActive {
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

                    // Time tooltip
                    if isActive {
                        let tooltipText = viewModel.timeText(for: hoverX / width)
                        Text(tooltipText)
                            .font(.caption)
                            .fontWeight(.medium)
                            .monospacedDigit()
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 6))
                            .foregroundStyle(.white)
                            .position(x: max(30, min(width - 30, clampedActiveX)),
                                      y: viewModel.seekPreviewImage != nil ? -10 : -16)
                            .transition(.opacity)
                    }
                }
                .frame(height: 24)

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
                Button {
                    viewModel.seekRelative(seconds: -10)
                } label: {
                    Image(systemName: "gobackward.10")
                        .font(.title2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)

                Button {
                    viewModel.togglePlayPause()
                } label: {
                    Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                        .font(.largeTitle)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)

                Button {
                    viewModel.seekRelative(seconds: 10)
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
