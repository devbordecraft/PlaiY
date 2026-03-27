import SwiftUI

struct PlayQueueView: View {
    @ObservedObject var queue: PlayQueue
    @Binding var isPresented: Bool
    let onJumpTo: (Int) -> Void

    var body: some View {
        ZStack(alignment: .trailing) {
            // Tap-to-dismiss background
            Color.black.opacity(0.3)
                .ignoresSafeArea()
                #if !os(tvOS)
                .onTapGesture {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                        isPresented = false
                    }
                }
                #endif

            // Side panel
            VStack(alignment: .leading, spacing: 0) {
                // Header
                VStack(alignment: .leading, spacing: 4) {
                    Text("Play Queue")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(.white.opacity(0.6))
                        .textCase(.uppercase)

                    Text("\(queue.items.count) item\(queue.items.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.4))
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 12)

                // Shuffle / Repeat controls
                HStack(spacing: 16) {
                    Button {
                        queue.toggleShuffle()
                    } label: {
                        Image(systemName: "shuffle")
                            .font(.body)
                            .fontWeight(.semibold)
                            .foregroundStyle(queue.shuffleEnabled ? .blue : .white.opacity(0.6))
                    }
                    .buttonStyle(.plain)

                    Button {
                        queue.cycleRepeatMode()
                    } label: {
                        Image(systemName: repeatIcon)
                            .font(.body)
                            .fontWeight(.semibold)
                            .foregroundStyle(queue.repeatMode != .off ? .blue : .white.opacity(0.6))
                    }
                    .buttonStyle(.plain)

                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 12)

                Divider()
                    .padding(.horizontal, 20)

                // Queue item list
                List {
                    ForEach(Array(queue.items.enumerated()), id: \.element.id) { index, item in
                        queueRow(item: item, index: index)
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets(top: 2, leading: 20, bottom: 2, trailing: 12))
                    }
                    .onMove { source, destination in
                        queue.move(from: source, to: destination)
                    }
                    .onDelete { offsets in
                        queue.remove(at: offsets)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)

                Divider()
                    .padding(.horizontal, 20)

                // Clear queue button
                Button {
                    queue.clear()
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                        isPresented = false
                    }
                } label: {
                    HStack {
                        Image(systemName: "trash")
                            .font(.caption)
                        Text("Clear Queue")
                            .font(.body)
                    }
                    .foregroundStyle(.red.opacity(0.8))
                    .padding(.vertical, 12)
                    .padding(.horizontal, 20)
                }
                .buttonStyle(.plain)
            }
            .frame(width: LayoutMetrics.panelWidth)
            .glassEffect(.regular, in: .rect(cornerRadius: 0))
            .environment(\.colorScheme, .dark)
            .transition(.move(edge: .trailing))
        }
        #if os(tvOS)
        .onExitCommand {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                isPresented = false
            }
        }
        #endif
    }

    private func queueRow(item: PlayQueue.Item, index: Int) -> some View {
        Button {
            onJumpTo(index)
        } label: {
            HStack(spacing: 10) {
                if index == queue.currentIndex {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.caption2)
                        .foregroundStyle(.blue)
                        .frame(width: 20)
                } else {
                    Text("\(index + 1)")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.4))
                        .frame(width: 20)
                }

                Text(item.displayName)
                    .font(.body)
                    .foregroundStyle(index == queue.currentIndex ? .blue : .white.opacity(0.8))
                    .lineLimit(1)

                Spacer()
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var repeatIcon: String {
        switch queue.repeatMode {
        case .off, .all: return "repeat"
        case .one: return "repeat.1"
        }
    }
}
