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
                    withAnimation(.easeInOut(duration: 0.25)) {
                        isPresented = false
                    }
                }

            // Side panel
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
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

                        if viewModel.passthroughActive {
                            Text("Bitstream active")
                                .font(.caption)
                                .foregroundStyle(.green.opacity(0.8))
                                .padding(.leading, 4)
                        }
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
