import SwiftUI

enum BrowseTheme {
    static let accent = Color(red: 0.98, green: 0.62, blue: 0.29)
    static let primaryText = Color.white.opacity(0.96)
    static let secondaryText = Color.white.opacity(0.74)
    static let tertiaryText = Color.white.opacity(0.54)
    static let cardHighlight = Color.white.opacity(0.14)
    static let cardShadow = Color.white.opacity(0.05)
    static let elevatedFill = Color.white.opacity(0.08)
    static let subduedFill = Color.white.opacity(0.06)
    static let divider = Color.white.opacity(0.09)
    static let destructive = Color(red: 0.96, green: 0.43, blue: 0.38)
    static let backdropTop = Color(red: 0.10, green: 0.10, blue: 0.12)
    static let backdropBottom = Color(red: 0.06, green: 0.07, blue: 0.10)
    static let backdropAccentA = Color.orange.opacity(0.22)
    static let backdropAccentB = Color(red: 0.16, green: 0.50, blue: 0.72).opacity(0.18)
    static let artworkBorder = Color.white.opacity(0.08)
    static let artworkBadgeBorder = Color.white.opacity(0.1)
    static let artworkShadow = Color.black.opacity(0.26)
    static let artworkPlaceholderBase = Color.white.opacity(0.08)
    static let artworkPlaceholderHighlight = Color.white.opacity(0.18)
    static let progressTrack = Color.black.opacity(0.35)
}

struct BrowseCardBackground: View {
    var cornerRadius: CGFloat = 24

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [BrowseTheme.cardHighlight, BrowseTheme.cardShadow],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(BrowseTheme.divider, lineWidth: 1)
            )
    }
}

struct BrowseDivider: View {
    var inset: CGFloat = 18

    var body: some View {
        Rectangle()
            .fill(BrowseTheme.divider)
            .frame(height: 1)
            .padding(.leading, inset)
    }
}
