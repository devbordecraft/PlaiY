import SwiftUI

struct MediaItemView: View {
    let item: LibraryItem
    let browseItem: BrowseItem?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            MediaArtworkView(
                descriptor: .libraryItem(item, browseItem: browseItem),
                style: .landscapeCard
            )

            VStack(alignment: .leading, spacing: 8) {
                Text(item.title)
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                metadataChips

                if !item.fileSizeText.isEmpty {
                    Text(item.fileSizeText)
                        .font(.caption)
                        .foregroundStyle(BrowseTheme.secondaryText)
                }
            }
        }
        .padding(14)
        .background(BrowseCardBackground(cornerRadius: 18))
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

    private var metadataChips: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                if !item.resolutionText.isEmpty {
                    MediaMetadataChip(text: item.resolutionText)
                }
                if !item.hdrText.isEmpty {
                    MediaMetadataChip(text: item.hdrText, tint: BrowseTheme.accent)
                }
                if !item.videoCodec.isEmpty {
                    MediaMetadataChip(text: item.videoCodec.uppercased())
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                if !item.resolutionText.isEmpty {
                    MediaMetadataChip(text: item.resolutionText)
                }
                if !item.hdrText.isEmpty {
                    MediaMetadataChip(text: item.hdrText, tint: BrowseTheme.accent)
                }
                if !item.videoCodec.isEmpty {
                    MediaMetadataChip(text: item.videoCodec.uppercased())
                }
            }
        }
    }
}

struct MediaMetadataChip: View {
    let text: String
    var tint: Color = BrowseTheme.primaryText

    var body: some View {
        Text(text)
            .font(.caption2)
            .fontWeight(.semibold)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .foregroundStyle(tint)
            .background(BrowseTheme.elevatedFill, in: Capsule())
            .overlay(
                Capsule()
                    .stroke(BrowseTheme.divider, lineWidth: 1)
            )
    }
}
