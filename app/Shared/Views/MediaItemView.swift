import SwiftUI

struct MediaItemView: View {
    let item: LibraryItem
    @State private var thumbnail: PlatformImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Thumbnail
            ZStack {
                if let thumbnail {
                    thumbnailImage(thumbnail)
                        .resizable()
                        .aspectRatio(16.0/9.0, contentMode: .fill)
                        .clipped()
                        .cornerRadius(8)
                } else {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.gray.opacity(0.2))
                        .aspectRatio(16.0/9.0, contentMode: .fit)

                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 36))
                        .foregroundStyle(.white.opacity(0.7))
                }

                // Duration badge + progress bar
                VStack(spacing: 0) {
                    Spacer()
                    HStack {
                        Spacer()
                        Text(item.durationText)
                            .font(.caption)
                            .fontWeight(.medium)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .foregroundStyle(.white)
                            .glassEffect(.regular, in: .rect(cornerRadius: 4))
                    }
                    .padding(8)

                    if let pos = ResumeStore.position(for: item.filePath),
                       item.durationUs > 0 {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Rectangle()
                                    .fill(.white.opacity(0.2))
                                Rectangle()
                                    .fill(.red)
                                    .frame(width: geo.size.width * min(Double(pos) / Double(item.durationUs), 1.0))
                            }
                        }
                        .frame(height: 3)
                    }
                }
            }
            .task(id: item.filePath) {
                thumbnail = await ThumbnailManager.shared.loadThumbnail(for: item.filePath)
            }

            // Title
            Text(item.title)
                .font(.headline)
                .lineLimit(2)

            // Info badges
            HStack(spacing: 6) {
                if !item.resolutionText.isEmpty {
                    BadgeView(text: item.resolutionText)
                }
                if !item.hdrText.isEmpty {
                    BadgeView(text: item.hdrText, color: .orange)
                }
                if !item.videoCodec.isEmpty {
                    BadgeView(text: item.videoCodec.uppercased())
                }
            }

            // File size
            Text(item.fileSizeText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(8)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 12))
        #if os(macOS)
        .onHover { hovering in
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
        #endif
    }

    private func thumbnailImage(_ image: PlatformImage) -> Image {
        #if os(macOS)
        Image(nsImage: image)
        #else
        Image(uiImage: image)
        #endif
    }
}

struct BadgeView: View {
    let text: String
    var color: Color = .secondary

    var body: some View {
        Text(text)
            .font(.caption2)
            .fontWeight(.semibold)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .foregroundStyle(color)
            .glassEffect(.regular, in: .rect(cornerRadius: 3))
    }
}
