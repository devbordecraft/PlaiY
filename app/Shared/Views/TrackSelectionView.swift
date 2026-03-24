import SwiftUI

struct TrackSelectionView: View {
    @ObservedObject var viewModel: PlayerViewModel
    @Binding var isPresented: Bool

    var body: some View {
        ZStack(alignment: .trailing) {
            // Tap-to-dismiss background
            Color.black.opacity(0.3)
                .ignoresSafeArea()
                .onTapGesture {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                        isPresented = false
                    }
                }

            // Side panel
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // Video section (aspect ratio, crop, zoom)
                    trackSection(title: "Video") {
                        ForEach(AspectRatioMode.allCases) { mode in
                            trackRow(
                                label: mode.displayName,
                                isSelected: viewModel.aspectRatioMode == mode
                            ) {
                                viewModel.setAspectRatioMode(mode)
                            }
                        }

                        Divider().padding(.vertical, 4)

                        Button {
                            viewModel.detectBlackBars()
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "crop")
                                    .font(.caption)
                                Text("Auto-Detect Black Bars")
                                    .font(.body)
                                Spacer()
                            }
                            .foregroundStyle(.white.opacity(0.8))
                            .padding(.vertical, 8)
                            .padding(.horizontal, 4)
                        }
                        .buttonStyle(.plain)

                        if viewModel.cropActive {
                            Button {
                                viewModel.setCrop(.zero)
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "arrow.uturn.backward")
                                        .font(.caption)
                                    Text("Remove Crop")
                                        .font(.body)
                                    Spacer()
                                }
                                .foregroundStyle(.orange.opacity(0.8))
                                .padding(.vertical, 4)
                                .padding(.horizontal, 4)
                            }
                            .buttonStyle(.plain)
                        }

                        let zoom = viewModel.transport.displaySettings.zoom
                        if zoom > 1.01 {
                            Divider().padding(.vertical, 4)
                            HStack {
                                Text("Zoom: \(String(format: "%.0f%%", zoom * 100))")
                                    .font(.caption)
                                    .foregroundStyle(.white.opacity(0.6))
                                Spacer()
                                Button("Reset") {
                                    viewModel.setZoom(1.0)
                                    viewModel.setPan(x: 0, y: 0)
                                }
                                .font(.caption)
                                .foregroundStyle(.orange.opacity(0.8))
                                .buttonStyle(.plain)
                            }
                            .padding(.vertical, 4)
                        }

                        Text("Pinch or =/\u{2212} to zoom, drag to pan, 0 to reset")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.3))
                            .padding(.leading, 4)
                            .padding(.top, 4)
                    }

                    // Subtitles section
                    if !viewModel.subtitleTracks.isEmpty {
                        trackSection(title: "Subtitles") {
                            trackRow(
                                label: "Off",
                                isSelected: viewModel.activeSubtitleStream == -1
                            ) {
                                viewModel.disableSubtitles()
                            }

                            ForEach(viewModel.subtitleTracks) { track in
                                trackRow(
                                    label: track.displayName,
                                    isSelected: viewModel.activeSubtitleStream == track.streamIndex
                                ) {
                                    viewModel.selectSubtitleTrack(streamIndex: track.streamIndex)
                                }
                            }
                        }
                    }

                    // Audio section
                    if !viewModel.audioTracks.isEmpty {
                        trackSection(title: "Audio") {
                            ForEach(viewModel.audioTracks) { track in
                                trackRow(
                                    label: track.displayName,
                                    isSelected: viewModel.activeAudioStream == track.streamIndex
                                ) {
                                    viewModel.selectAudioTrack(streamIndex: track.streamIndex)
                                }
                            }
                        }
                    }

                    // Speed section
                    trackSection(title: "Speed") {
                        ForEach([0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0, 4.0], id: \.self) { speed in
                            trackRow(
                                label: speed == Double(Int(speed))
                                    ? "\(Int(speed))x"
                                    : String(format: "%.2gx", speed),
                                isSelected: abs(viewModel.playbackSpeed - speed) < 0.01
                            ) {
                                viewModel.setPlaybackSpeed(speed)
                            }
                        }
                    }

                    // Output section
                    trackSection(title: "Output") {
                        HStack {
                            Toggle("Audio Passthrough", isOn: Binding(
                                get: { viewModel.passthroughEnabled },
                                set: { viewModel.setPassthrough($0) }
                            ))
                            .toggleStyle(.switch)
                            .foregroundStyle(.white)
                        }
                        .padding(.vertical, 4)

                        if viewModel.transport.passthroughActive {
                            Text("Bitstream active")
                                .font(.caption)
                                .foregroundStyle(.green.opacity(0.8))
                                .padding(.leading, 4)
                        }

                        // Device capability summary
                        let caps = viewModel.passthroughCaps
                        let supported = [
                            caps.ac3 ? "AC3" : nil,
                            caps.eac3 ? "E-AC3" : nil,
                            caps.dts ? "DTS" : nil,
                            caps.dts_hd_ma ? "DTS-HD" : nil,
                            caps.truehd ? "TrueHD" : nil,
                        ].compactMap { $0 }
                        if supported.isEmpty {
                            Text("No passthrough formats detected")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.4))
                                .padding(.leading, 4)
                        } else {
                            Text("Device supports: \(supported.joined(separator: ", "))")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.5))
                                .padding(.leading, 4)
                        }

                        Divider().padding(.vertical, 4)

                        // Spatial Audio
                        HStack {
                            Text("Spatial Audio")
                                .foregroundStyle(.white)
                            Spacer()
                            Picker("", selection: Binding(
                                get: { viewModel.bridge.spatialAudioMode },
                                set: { viewModel.setSpatialMode(Int($0)) }
                            )) {
                                Text("Auto").tag(Int32(0))
                                Text("Off").tag(Int32(1))
                                Text("Force").tag(Int32(2))
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 160)
                        }
                        .padding(.vertical, 2)

                        if viewModel.transport.spatialActive {
                            Text("Spatial audio active (HRTF)")
                                .font(.caption)
                                .foregroundStyle(.blue.opacity(0.8))
                                .padding(.leading, 4)
                        }

                        Toggle("Head Tracking", isOn: Binding(
                            get: { viewModel.headTrackingEnabled },
                            set: { viewModel.setHeadTracking($0) }
                        ))
                        .toggleStyle(.switch)
                        .foregroundStyle(.white)
                        .padding(.vertical, 2)
                    }
                }
                .padding(20)
            }
            .frame(width: 280)
            .background(.ultraThinMaterial)
            .environment(\.colorScheme, .dark)
            .transition(.move(edge: .trailing))
        }
    }

    @ViewBuilder
    private func trackSection(title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(.white.opacity(0.6))
                .textCase(.uppercase)

            VStack(alignment: .leading, spacing: 0) {
                content()
            }
        }
    }

    private func trackRow(label: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "checkmark")
                    .font(.caption)
                    .fontWeight(.bold)
                    .opacity(isSelected ? 1 : 0)

                Text(label)
                    .font(.body)

                Spacer()
            }
            .foregroundStyle(isSelected ? .white : .white.opacity(0.8))
            .padding(.vertical, 8)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
