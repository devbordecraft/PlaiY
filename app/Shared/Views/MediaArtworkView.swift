import Foundation
import SwiftUI

enum MediaArtworkCandidateSource: String, Hashable, Sendable {
    case poster
    case backdrop
}

enum MediaArtworkPlacement: String, Hashable, Sendable {
    case fill
    case fit

    var contentMode: ContentMode {
        switch self {
        case .fill:
            return .fill
        case .fit:
            return .fit
        }
    }
}

enum MediaArtworkSurfaceStyle: String, Hashable, Sendable {
    case posterCard
    case landscapeCard
    case landscapeRow

    var aspectRatio: CGFloat {
        switch self {
        case .posterCard:
            return 0.68
        case .landscapeCard:
            return 16.0 / 9.0
        case .landscapeRow:
            return 1.4
        }
    }

    var cornerRadius: CGFloat {
        switch self {
        case .posterCard:
            return 24
        case .landscapeCard:
            return 20
        case .landscapeRow:
            return 18
        }
    }

    var overlayPadding: CGFloat {
        switch self {
        case .posterCard:
            return 12
        case .landscapeCard:
            return 12
        case .landscapeRow:
            return 10
        }
    }

    var progressInset: CGFloat {
        switch self {
        case .posterCard:
            return 12
        case .landscapeCard:
            return 10
        case .landscapeRow:
            return 10
        }
    }

    var shadowRadius: CGFloat {
        switch self {
        case .posterCard:
            return 18
        case .landscapeCard:
            return 12
        case .landscapeRow:
            return 0
        }
    }

    var shadowYOffset: CGFloat {
        switch self {
        case .posterCard:
            return 10
        case .landscapeCard:
            return 6
        case .landscapeRow:
            return 0
        }
    }

    var overlayOpacity: Double {
        switch self {
        case .posterCard:
            return 0.62
        case .landscapeCard:
            return 0.5
        case .landscapeRow:
            return 0.44
        }
    }

    var fallbackTitleSize: CGFloat {
        switch self {
        case .posterCard:
            return 20
        case .landscapeCard:
            return 16
        case .landscapeRow:
            return 15
        }
    }

    var fallbackIconSize: CGFloat {
        switch self {
        case .posterCard:
            return 34
        case .landscapeCard:
            return 30
        case .landscapeRow:
            return 26
        }
    }

    var fallbackTitleLineLimit: Int {
        switch self {
        case .posterCard:
            return 3
        case .landscapeCard:
            return 2
        case .landscapeRow:
            return 2
        }
    }

    var defaultCandidateOrder: [MediaArtworkCandidateSource] {
        switch self {
        case .posterCard:
            return [.poster, .backdrop]
        case .landscapeCard, .landscapeRow:
            return [.backdrop, .poster]
        }
    }
}

enum MediaArtworkAsset: Hashable, Sendable {
    case local(source: MediaArtworkCandidateSource, path: String)
    case remote(source: MediaArtworkCandidateSource, url: URL)

    var source: MediaArtworkCandidateSource {
        switch self {
        case let .local(source, _), let .remote(source, _):
            return source
        }
    }
}

struct MediaArtworkRendering: Hashable, Sendable {
    let placement: MediaArtworkPlacement
    let padding: CGFloat
}

struct MediaArtworkDescriptor: Hashable {
    enum Palette: String, Hashable, Sendable {
        case local
        case plex
        case pin
        case neutral
        case folder

        var gradient: LinearGradient {
            let colors: [Color]
            switch self {
            case .local:
                colors = [
                    Color(red: 0.98, green: 0.58, blue: 0.27),
                    Color(red: 0.31, green: 0.16, blue: 0.12)
                ]
            case .plex:
                colors = [
                    Color(red: 0.43, green: 0.35, blue: 0.76),
                    Color(red: 0.11, green: 0.13, blue: 0.24)
                ]
            case .pin:
                colors = [
                    Color(red: 0.22, green: 0.64, blue: 0.74),
                    Color(red: 0.08, green: 0.22, blue: 0.29)
                ]
            case .neutral:
                colors = [
                    Color.white.opacity(0.16),
                    Color(red: 0.11, green: 0.12, blue: 0.15)
                ]
            case .folder:
                colors = [
                    Color(red: 0.25, green: 0.48, blue: 0.9),
                    Color(red: 0.08, green: 0.18, blue: 0.34)
                ]
            }
            return LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }

    let title: String
    let posterPath: String?
    let posterURL: String?
    let backdropPath: String?
    let backdropURL: String?
    let badge: String?
    let progress: Double?
    let isWatched: Bool
    let palette: Palette
    let fallbackIconName: String?

    init(title: String,
         posterPath: String? = nil,
         posterURL: String? = nil,
         backdropPath: String? = nil,
         backdropURL: String? = nil,
         badge: String? = nil,
         progress: Double? = nil,
         isWatched: Bool = false,
         palette: Palette = .neutral,
         fallbackIconName: String? = nil) {
        self.title = title
        self.posterPath = posterPath
        self.posterURL = posterURL
        self.backdropPath = backdropPath
        self.backdropURL = backdropURL
        self.badge = badge
        self.progress = progress
        self.isWatched = isWatched
        self.palette = palette
        self.fallbackIconName = fallbackIconName
    }

    var hasArtwork: Bool {
        !orderedAssets(for: .posterCard).isEmpty
    }

    func orderedAssets(for style: MediaArtworkSurfaceStyle) -> [MediaArtworkAsset] {
        var assets: [MediaArtworkAsset] = []

        for source in style.defaultCandidateOrder {
            switch source {
            case .poster:
                if let posterPath, !posterPath.isEmpty {
                    assets.append(.local(source: .poster, path: posterPath))
                }
                if let posterURL, let url = URL(string: posterURL) {
                    assets.append(.remote(source: .poster, url: url))
                }
            case .backdrop:
                if let backdropPath, !backdropPath.isEmpty {
                    assets.append(.local(source: .backdrop, path: backdropPath))
                }
                if let backdropURL, let url = URL(string: backdropURL) {
                    assets.append(.remote(source: .backdrop, url: url))
                }
            }
        }

        return assets
    }

    func rendering(for asset: MediaArtworkAsset,
                   in style: MediaArtworkSurfaceStyle) -> MediaArtworkRendering {
        switch style {
        case .posterCard:
            return MediaArtworkRendering(placement: .fill, padding: 0)
        case .landscapeCard, .landscapeRow:
            if asset.source == .poster {
                return MediaArtworkRendering(placement: .fit, padding: 8)
            }
            return MediaArtworkRendering(placement: .fill, padding: 0)
        }
    }

    static func browseItem(_ item: BrowseItem) -> MediaArtworkDescriptor {
        MediaArtworkDescriptor(
            title: item.title,
            posterPath: item.artwork.posterPath,
            posterURL: item.artwork.posterURL,
            backdropPath: item.artwork.backdropPath,
            backdropURL: item.artwork.backdropURL,
            badge: item.badge,
            progress: item.progress,
            isWatched: item.isWatched,
            palette: palette(for: item),
            fallbackIconName: fallbackIconName(for: item)
        )
    }

    static func libraryItem(_ item: LibraryItem,
                            browseItem: BrowseItem?) -> MediaArtworkDescriptor {
        MediaArtworkDescriptor(
            title: item.title,
            posterPath: browseItem?.artwork.posterPath,
            posterURL: browseItem?.artwork.posterURL,
            backdropPath: browseItem?.artwork.backdropPath,
            backdropURL: browseItem?.artwork.backdropURL,
            badge: browseItem?.badge ?? primaryBadge(for: item),
            progress: browseItem?.progress ?? progress(for: item),
            isWatched: browseItem?.isWatched ?? watched(for: item),
            palette: .local,
            fallbackIconName: "play.circle.fill"
        )
    }

    static func sourceEntry(_ entry: SourceEntry) -> MediaArtworkDescriptor {
        let posterURL = normalizedURLString(entry.plex?.thumbURL)
        let backdropURL = normalizedURLString(entry.plex?.artURL)

        return MediaArtworkDescriptor(
            title: entry.name,
            posterURL: posterURL,
            backdropURL: backdropURL,
            progress: entry.progressFraction,
            isWatched: entry.isWatched,
            palette: entry.plex == nil ? (entry.isDirectory ? .folder : .neutral) : .plex,
            fallbackIconName: entry.isDirectory ? "folder.fill" : "play.circle.fill"
        )
    }

    private static func palette(for item: BrowseItem) -> Palette {
        switch item.source {
        case .local:
            return .local
        case .plex:
            return .plex
        case .pin:
            return .pin
        }
    }

    private static func fallbackIconName(for item: BrowseItem) -> String? {
        switch item.kind {
        case .folder:
            return "folder.fill"
        case .source:
            if let rawValue = item.sourceTypeRawValue,
               let sourceType = SourceType(rawValue: rawValue) {
                return sourceType.systemImage
            }
            return "externaldrive.fill"
        case .movie, .show, .episode:
            return nil
        }
    }

    private static func primaryBadge(for item: LibraryItem) -> String? {
        if !item.hdrText.isEmpty {
            return item.hdrText
        }
        if !item.resolutionText.isEmpty {
            return item.resolutionText
        }
        return nil
    }

    private static func progress(for item: LibraryItem) -> Double? {
        guard let position = ResumeStore.position(for: item.filePath),
              item.durationUs > 0 else {
            return nil
        }
        return min(max(Double(position) / Double(item.durationUs), 0), 1)
    }

    private static func watched(for item: LibraryItem) -> Bool {
        guard let position = ResumeStore.position(for: item.filePath),
              item.durationUs > 0 else {
            return false
        }
        return Double(position) / Double(item.durationUs) >= 0.95
    }

    private static func normalizedURLString(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}

struct MediaArtworkView: View {
    let descriptor: MediaArtworkDescriptor
    let style: MediaArtworkSurfaceStyle

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous)
    }

    private var orderedAssets: [MediaArtworkAsset] {
        descriptor.orderedAssets(for: style)
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            descriptor.palette.gradient

            ArtworkImageSequenceView(
                assets: orderedAssets,
                success: { asset, image in
                    platformImageView(
                        image,
                        rendering: descriptor.rendering(for: asset, in: style)
                    )
                },
                loading: {
                    loadingContent
                },
                fallback: {
                    fallbackContent
                }
            )

            LinearGradient(
                colors: [.clear, .black.opacity(style.overlayOpacity)],
                startPoint: .center,
                endPoint: .bottom
            )

            artworkOverlay
        }
        .aspectRatio(style.aspectRatio, contentMode: .fit)
        .clipShape(shape)
        .overlay(
            shape.stroke(BrowseTheme.artworkBorder, lineWidth: 1)
        )
        .shadow(color: BrowseTheme.artworkShadow,
                radius: style.shadowRadius,
                y: style.shadowYOffset)
    }

    private var loadingContent: some View {
        ArtworkLoadingPlaceholder(
            cornerRadius: style.cornerRadius,
            iconName: descriptor.fallbackIconName
        )
    }

    private var fallbackContent: some View {
        ZStack(alignment: .bottomLeading) {
            if let fallbackIconName = descriptor.fallbackIconName {
                Image(systemName: fallbackIconName)
                    .font(.system(size: style.fallbackIconSize, weight: .semibold))
                    .foregroundStyle(BrowseTheme.primaryText.opacity(0.84))
                    .padding(style.overlayPadding)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }

            Text(descriptor.title)
                .font(.system(size: style.fallbackTitleSize, weight: .black, design: .rounded))
                .foregroundStyle(BrowseTheme.primaryText.opacity(0.92))
                .lineLimit(style.fallbackTitleLineLimit)
                .padding(style.overlayPadding)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var artworkOverlay: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                if let badge = descriptor.badge, !badge.isEmpty {
                    artworkBadge(badge)
                }

                Spacer(minLength: 0)

                if descriptor.isWatched {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.white, .green)
                }
            }
            .padding(style.overlayPadding)

            Spacer(minLength: 0)

            if let progress = descriptor.progress {
                progressBar(progress)
                    .padding(.horizontal, style.progressInset)
                    .padding(.bottom, style.progressInset)
            }
        }
    }

    private func artworkBadge(_ title: String) -> some View {
        Text(title)
            .font(.caption2)
            .fontWeight(.bold)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.black.opacity(0.5), in: Capsule())
            .overlay(
                Capsule()
                    .stroke(BrowseTheme.artworkBadgeBorder, lineWidth: 1)
            )
            .foregroundStyle(.white)
    }

    private func progressBar(_ progress: Double) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(BrowseTheme.progressTrack)
                Capsule()
                    .fill(BrowseTheme.accent.gradient)
                    .frame(width: proxy.size.width * min(max(progress, 0), 1))
            }
        }
        .frame(height: 4)
    }

    @ViewBuilder
    private func platformImageView(_ image: PlatformImage,
                                   rendering: MediaArtworkRendering) -> some View {
        #if os(macOS)
        Image(nsImage: image)
            .resizable()
            .aspectRatio(contentMode: rendering.placement.contentMode)
            .padding(rendering.padding)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
        #else
        Image(uiImage: image)
            .resizable()
            .aspectRatio(contentMode: rendering.placement.contentMode)
            .padding(rendering.padding)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
        #endif
    }
}

private struct ArtworkLoadingPlaceholder: View {
    let cornerRadius: CGFloat
    let iconName: String?

    @State private var phase: CGFloat = -1

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Rectangle()
                    .fill(BrowseTheme.artworkPlaceholderBase)

                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [
                                .clear,
                                BrowseTheme.artworkPlaceholderHighlight,
                                .clear
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: max(proxy.size.width * 0.42, 44))
                    .rotationEffect(.degrees(18))
                    .offset(x: phase * max(proxy.size.width * 1.4, 120))

                if let iconName {
                    Image(systemName: iconName)
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(BrowseTheme.primaryText.opacity(0.24))
                }
            }
            .clipShape(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .task {
                guard phase < 0 else { return }
                withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                    phase = 1
                }
            }
        }
    }
}
