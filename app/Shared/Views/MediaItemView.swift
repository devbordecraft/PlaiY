import SwiftUI

struct MediaItemView: View {
    let item: LibraryItem
    @State private var thumbnail: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Thumbnail
            ZStack {
                if let thumbnail {
                    Image(nsImage: thumbnail)
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

                // Duration badge
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Text(item.durationText)
                            .font(.caption)
                            .fontWeight(.medium)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.black.opacity(0.7))
                            .foregroundStyle(.white)
                            .cornerRadius(4)
                    }
                }
                .padding(8)
            }
            .task {
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
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.background)
                .shadow(color: .black.opacity(0.1), radius: 4, y: 2)
        )
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
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .cornerRadius(3)
    }
}
