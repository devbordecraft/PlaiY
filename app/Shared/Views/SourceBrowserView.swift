import SwiftUI

struct SourceBrowserView: View {
    @ObservedObject var sourcesVM: SourcesViewModel
    let onSelect: (PlaybackItem) -> Void
    let onPlayAll: ([PlaybackItem]) -> Void
    let onSettings: () -> Void
    var selectedSourceID: String? = nil
    var selectedSourceToken: UUID? = nil

    @State private var showAddSource = false
    @State private var reconnectSource: SourceConfig?

    private let columns = [
        GridItem(.adaptive(minimum: LayoutMetrics.gridMinWidth,
                           maximum: LayoutMetrics.gridMaxWidth), spacing: 16)
    ]

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            sourceSelector
            content
        }
        .sheet(isPresented: $showAddSource) {
            AddSourceView(sourcesVM: sourcesVM) { showAddSource = false }
                .frame(minWidth: 450, minHeight: 350)
        }
        .sheet(item: $reconnectSource) { source in
            AddSourceView(sourcesVM: sourcesVM, reconnectSource: source) {
                reconnectSource = nil
            }
            .frame(minWidth: 450, minHeight: 350)
        }
        .onAppear {
            applyPinnedSourceSelection()
        }
        .onChange(of: selectedSourceToken) { _, _ in
            applyPinnedSourceSelection()
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        GlassEffectContainer {
            HStack {
                Text("Sources")
                    .font(.largeTitle)
                    .fontWeight(.bold)

                Spacer()

                Button {
                    onSettings()
                } label: {
                    Image(systemName: "gearshape")
                        .font(.title2)
                }
                .buttonStyle(.bordered)

                Button("Add Source") {
                    showAddSource = true
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
        }
    }

    // MARK: - Source selector

    private var sourceSelector: some View {
        Group {
            if !sourcesVM.sources.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(sourcesVM.sources) { source in
                            sourceChip(source)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                }
            }
        }
    }

    private func sourceChip(_ source: SourceConfig) -> some View {
        let isSelected = sourcesVM.currentSourceId == source.id
        let connected = sourcesVM.isConnected(sourceId: source.id)
        let needsReconnect = sourcesVM.needsReconnect(sourceId: source.id)

        return Button {
            if source.type == .plex && needsReconnect {
                reconnectSource = source
            } else {
                sourcesVM.openSourceRoot(sourceId: source.id)
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: source.type.systemImage)
                    .font(.caption)
                Text(source.displayName)
                    .font(.subheadline)
                    .fontWeight(isSelected ? .semibold : .regular)
                Circle()
                    .fill(needsReconnect ? .orange : (connected ? .green : .gray))
                    .frame(width: 6, height: 6)
                if needsReconnect {
                    Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .glassEffect(isSelected ? .regular.interactive() : .regular, in: .capsule)
        }
        #if os(tvOS)
        .buttonStyle(.bordered)
        #else
        .buttonStyle(.plain)
        .contextMenu {
            if source.type == .plex && needsReconnect {
                Button("Reconnect") {
                    reconnectSource = source
                }
            } else {
                Button(connected ? "Disconnect" : "Connect") {
                    if connected {
                        sourcesVM.disconnect(sourceId: source.id)
                    } else {
                        sourcesVM.connect(sourceId: source.id)
                    }
                }
            }
            Button("Remove", role: .destructive) {
                sourcesVM.removeSource(id: source.id)
            }
        }
        #endif
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if sourcesVM.sources.isEmpty {
            emptyState
        } else if sourcesVM.currentSourceId == nil {
            noSourceSelected
        } else if sourcesVM.isConnecting {
            connectingState
        } else {
            directoryListing
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "network")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("No sources configured")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("Add a share, server, or direct media URL to get started")
                .foregroundStyle(.tertiary)
            Button("Add Source") { showAddSource = true }
                .buttonStyle(.borderedProminent)
            Spacer()
        }
    }

    private var noSourceSelected: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "arrow.up.circle")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("Select a source above to browse")
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    private var connectingState: some View {
        VStack(spacing: 12) {
            Spacer()
            ProgressView()
            Text("Connecting...")
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    private var directoryListing: some View {
        VStack(spacing: 0) {
            // Breadcrumb bar
            if !sourcesVM.navigationPath.isEmpty {
                HStack(spacing: 4) {
                    Button {
                        sourcesVM.navigateToRoot()
                    } label: {
                        Image(systemName: "house")
                            .font(.caption)
                    }
                    #if os(tvOS)
                    .buttonStyle(.bordered)
                    #else
                    .buttonStyle(.plain)
                    #endif

                    ForEach(Array(sourcesVM.navigationDisplayNames.enumerated()), id: \.offset) { index, displayName in
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Button(displayName) {
                            let targetPath = Array(sourcesVM.navigationPath.prefix(index + 1))
                            let targetNames = Array(sourcesVM.navigationDisplayNames.prefix(index + 1))
                            sourcesVM.navigationPath = targetPath
                            sourcesVM.navigationDisplayNames = targetNames

                            let isPlex = sourcesVM.sources.first(where: { $0.id == sourcesVM.currentSourceId })?.type == .plex
                            let relativePath = isPlex ? (targetPath.last ?? "") : targetPath.joined(separator: "/")
                            sourcesVM.browse(
                                sourceId: sourcesVM.currentSourceId ?? "",
                                relativePath: relativePath
                            )
                        }
                        #if os(tvOS)
                        .buttonStyle(.bordered)
                        #else
                        .buttonStyle(.plain)
                        #endif
                        .font(.caption)
                    }

                    Spacer()

                    if hasMediaFiles {
                        Button {
                            onPlayAll(mediaPlaybackItems)
                        } label: {
                            Label("Play All", systemImage: "play.fill")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }

                    Button {
                        sourcesVM.navigateUp()
                    } label: {
                        Image(systemName: "arrow.up.circle")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(.horizontal)
                .padding(.vertical, 6)
            }

            // Error
            if let error = sourcesVM.error {
                HStack {
                    Image(systemName: "exclamationmark.triangle")
                    Text(error)
                    Spacer()
                    if let currentSourceId = sourcesVM.currentSourceId,
                       let source = sourcesVM.sources.first(where: { $0.id == currentSourceId }),
                       source.type == .plex,
                       sourcesVM.needsReconnect(sourceId: currentSourceId) {
                        Button("Reconnect") {
                            reconnectSource = source
                        }
                        .buttonStyle(.bordered)
                    }
                    Button("Dismiss") { sourcesVM.error = nil }
                }
                .font(.caption)
                .padding(.horizontal)
                .padding(.vertical, 4)
                .background(.red.opacity(0.1))
            }

            // Loading or entries
            if sourcesVM.isLoading {
                VStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
            } else if sourcesVM.currentEntries.isEmpty {
                VStack {
                    Spacer()
                    Text("Empty folder")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(sourcesVM.currentEntries) { entry in
                            if entry.isDirectory {
                                folderCard(entry)
                            } else {
                                fileCard(entry)
                            }
                        }
                    }
                    .padding()
                }
            }
        }
    }

    // MARK: - Entry cards

    private func folderCard(_ entry: SourceEntry) -> some View {
        Button {
            sourcesVM.navigateInto(entry)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                artworkCard(entry)

                Text(entry.name)
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .lineLimit(2)

                if let progressText = progressText(for: entry) {
                    Text(progressText)
                        .font(.caption)
                        .foregroundStyle(BrowseTheme.secondaryText)
                }
            }
            .padding(14)
            .background(BrowseCardBackground(cornerRadius: 18))
        }
        #if os(tvOS)
        .buttonStyle(.card)
        #else
        .buttonStyle(.plain)
        #endif
        #if os(macOS)
        .onHover { hovering in
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        #endif
    }

    private func fileCard(_ entry: SourceEntry) -> some View {
        Button {
            onSelect(sourcesVM.playbackItem(for: entry))
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                artworkCard(entry)

                Text(entry.name)
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .lineLimit(2)

                if let progressText = progressText(for: entry) {
                    Text(progressText)
                        .font(.caption)
                        .foregroundStyle(BrowseTheme.secondaryText)
                }

                if !entry.fileSizeText.isEmpty {
                    Text(entry.fileSizeText)
                        .font(.caption)
                        .foregroundStyle(BrowseTheme.secondaryText)
                }
            }
            .padding(14)
            .background(BrowseCardBackground(cornerRadius: 18))
        }
        #if os(tvOS)
        .buttonStyle(.card)
        #else
        .buttonStyle(.plain)
        #endif
        #if os(macOS)
        .onHover { hovering in
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        #endif
    }

    // MARK: - Play All helpers

    private var hasMediaFiles: Bool {
        sourcesVM.currentEntries.contains { !$0.isDirectory }
    }

    private var mediaPlaybackItems: [PlaybackItem] {
        sourcesVM.currentPlaybackItems()
    }

    @ViewBuilder
    private func artworkCard(_ entry: SourceEntry) -> some View {
        MediaArtworkView(
            descriptor: .sourceEntry(entry),
            style: .landscapeCard
        )
    }

    private func progressText(for entry: SourceEntry) -> String? {
        guard let plex = entry.plex else { return nil }
        if plex.leafCount > 0 {
            return "\(plex.viewedLeafCount) of \(plex.leafCount) watched"
        }
        if plex.isWatched {
            return "Watched"
        }
        if let fraction = plex.progressFraction {
            return "\(Int(fraction * 100))% watched"
        }
        return nil
    }

    private func applyPinnedSourceSelection() {
        guard let selectedSourceID, sourcesVM.sources.contains(where: { $0.id == selectedSourceID }) else {
            return
        }
        sourcesVM.openSourceRoot(sourceId: selectedSourceID)
    }
}
