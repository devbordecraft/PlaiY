import SwiftUI

struct BrowseShellView: View {
    @EnvironmentObject private var libraryVM: LibraryViewModel
    @EnvironmentObject private var settings: AppSettings
    @ObservedObject var sourcesVM: SourcesViewModel
    @ObservedObject var browseStore: BrowseStore
    let onPlay: (PlaybackItem) -> Void
    let onResume: (PlaybackItem) -> Void
    let onPlayAll: ([PlaybackItem]) -> Void

    @State private var detailPath: [BrowseItem] = []
    @State private var showCustomizeHome = false

    private var refreshSignature: String {
        [
            libraryVM.items.map {
                "\($0.id):\($0.durationUs):\($0.videoWidth)x\($0.videoHeight):\($0.hdrType)"
            }.joined(separator: "|"),
            libraryVM.folders.joined(separator: "|"),
            sourcesVM.sources.map {
                "\($0.id):\($0.displayName):\($0.type.rawValue):\($0.baseURI):\($0.username):\($0.authToken ?? "")"
            }.joined(separator: "|")
        ].joined(separator: "||")
    }

    var body: some View {
        Group {
            #if os(tvOS)
            tvShell
            #else
            splitShell
            #endif
        }
        .background(BrowseBackdrop().ignoresSafeArea())
        .environment(\.colorScheme, .dark)
        .tint(BrowseTheme.accent)
        .task(id: refreshSignature) {
            browseStore.refresh(
                libraryItems: libraryVM.items,
                folders: libraryVM.folders,
                sources: sourcesVM.sources,
                onPlexAuthInvalid: { sourceIds in
                    sourcesVM.handlePlexAuthFailures(sourceIds)
                }
            )
        }
        .sheet(isPresented: $showCustomizeHome) {
            HomeCustomizationView(browseStore: browseStore)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .onChange(of: browseStore.destination) { _, _ in
            detailPath = []
        }
    }

    #if !os(tvOS)
    private var splitShell: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            NavigationStack(path: $detailPath) {
                destinationRoot
                    .navigationDestination(for: BrowseItem.self) { item in
                            BrowseItemDetailView(
                                item: item,
                                browseStore: browseStore,
                                onPlay: onPlay,
                                onResume: onResume,
                                onOpenItem: selectItem
                            )
                    }
            }
        }
    }
    #endif

    #if os(tvOS)
    private var tvShell: some View {
        TabView(selection: $browseStore.destination) {
            ForEach(BrowseDestination.allCases.filter { $0 != .settings }, id: \.self) { destination in
                NavigationStack(path: $detailPath) {
                    destinationRoot(for: destination)
                        .navigationDestination(for: BrowseItem.self) { item in
                            BrowseItemDetailView(
                                item: item,
                                browseStore: browseStore,
                                onPlay: onPlay,
                                onResume: onResume,
                                onOpenItem: selectItem
                            )
                        }
                }
                .tabItem {
                    Label(destination.title, systemImage: destination.systemImage)
                }
                .tag(destination)
            }

            SettingsView(onDismiss: { browseStore.destination = .home })
                .environmentObject(settings)
                .environmentObject(libraryVM)
                .environmentObject(sourcesVM)
                .tabItem {
                    Label(BrowseDestination.settings.title, systemImage: BrowseDestination.settings.systemImage)
                }
                .tag(BrowseDestination.settings)
        }
    }
    #endif

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("PlaiY")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                Text("A more cinematic browse experience")
                    .font(.subheadline)
                    .foregroundStyle(BrowseTheme.secondaryText)
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)

            ScrollView {
                VStack(spacing: 8) {
                    ForEach(BrowseDestination.allCases, id: \.self) { destination in
                        SidebarDestinationButton(
                            destination: destination,
                            isSelected: browseStore.destination == destination
                        ) {
                            browseStore.destination = destination
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
            }

            Spacer()

            VStack(alignment: .leading, spacing: 8) {
                Text("Sources")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(BrowseTheme.secondaryText)
                Text(sourcesVM.sources.isEmpty ? "No sources configured" : "\(sourcesVM.sources.count) sources available")
                    .font(.footnote)
                    .foregroundStyle(BrowseTheme.secondaryText)
            }
            .padding(18)
        }
        .frame(minWidth: 250)
        .background(.ultraThinMaterial.opacity(0.88))
    }

    @ViewBuilder
    private var destinationRoot: some View {
        destinationRoot(for: browseStore.destination)
    }

    @ViewBuilder
    private func destinationRoot(for destination: BrowseDestination) -> some View {
        switch destination {
        case .home:
            BrowseHomeView(
                browseStore: browseStore,
                onSelectItem: selectItem,
                onCustomize: { showCustomizeHome = true }
            )
        case .search:
            BrowseSearchView(
                browseStore: browseStore,
                onSelectItem: selectItem
            )
        case .movies:
            BrowseGridView(
                title: "Movies",
                subtitle: "Your local library and Plex catalog in one place",
                items: browseStore.items(for: .movies),
                onSelectItem: selectItem
            )
        case .shows:
            BrowseGridView(
                title: "TV Shows",
                subtitle: "Series, seasons, and in-progress episodes",
                items: browseStore.items(for: .shows),
                onSelectItem: selectItem
            )
        case .favorites:
            BrowseGridView(
                title: "Favorites",
                subtitle: "Hand-picked titles and series you want close",
                items: browseStore.items(for: .favorites),
                onSelectItem: selectItem
            )
        case .files:
            FilesHubView(
                browseStore: browseStore,
                sourcesVM: sourcesVM,
                onPlay: onPlay,
                onPlayAll: onPlayAll,
                onOpenLocalItem: { item in
                    detailPath.append(item)
                },
                onOpenSettings: {
                    browseStore.destination = .settings
                }
            )
            .environmentObject(libraryVM)
        case .settings:
            SettingsView(onDismiss: { browseStore.destination = .home })
                .environmentObject(settings)
                .environmentObject(libraryVM)
                .environmentObject(sourcesVM)
        }
    }

    private func selectItem(_ item: BrowseItem) {
        guard item.source != .pin else {
            _ = browseStore.resolvePinnedItem(item)
            return
        }
        detailPath.append(item)
    }
}

private struct BrowseHomeView: View {
    @ObservedObject var browseStore: BrowseStore
    let onSelectItem: (BrowseItem) -> Void
    let onCustomize: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                BrowseHeroHeader(
                    eyebrow: "Home",
                    title: "Browse your library like a collection, not a folder tree.",
                    subtitle: "Movies, shows, favorites, progress, and Plex all in one media-first space.",
                    trailing: {
                        HStack(spacing: 12) {
                            if browseStore.isRefreshingPlex {
                                ProgressView()
                                    .controlSize(.small)
                            }

                            Button("Customize Home", systemImage: "slider.horizontal.3") {
                                onCustomize()
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                )

                ForEach(browseStore.homeShelves(), id: \.id) { shelf in
                    BrowseShelfView(shelf: shelf, onSelectItem: onSelectItem)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 28)
        }
    }
}

private struct BrowseSearchView: View {
    @ObservedObject var browseStore: BrowseStore
    let onSelectItem: (BrowseItem) -> Void

    private var localResults: [BrowseItem] {
        browseStore.searchResults.filter { $0.source == .local }
    }

    private var plexResults: [BrowseItem] {
        browseStore.searchResults.filter { $0.source == .plex }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                BrowseHeroHeader(
                    eyebrow: "Search",
                    title: "Find titles across local media and Plex.",
                    subtitle: "Search is live for Plex and immediate for your local library.",
                    trailing: {
                        EmptyView()
                    }
                )

                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(BrowseTheme.secondaryText)
                    TextField("Search movies, shows, or episodes", text: Binding(
                        get: { browseStore.searchText },
                        set: { browseStore.updateSearch(text: $0) }
                    ))
                    .textFieldStyle(.plain)
                    .onSubmit {
                        browseStore.submitSearch()
                    }

                    if browseStore.isSearching {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(BrowseTheme.elevatedFill)
                )

                if browseStore.searchText.isEmpty {
                    recentQueryBlock
                } else if browseStore.searchResults.isEmpty, !browseStore.isSearching {
                    BrowseEmptyState(
                        icon: "sparkle.magnifyingglass",
                        title: "No matches yet",
                        subtitle: "Try a shorter title, a year, or switch to Files for raw browsing."
                    )
                } else {
                    if !localResults.isEmpty {
                        BrowseSearchSection(title: "Local Library", items: localResults, onSelectItem: onSelectItem)
                    }
                    if !plexResults.isEmpty {
                        BrowseSearchSection(title: "Plex", items: plexResults, onSelectItem: onSelectItem)
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 28)
        }
    }

    private var recentQueryBlock: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Recent Searches")
                .font(.system(size: 22, weight: .bold, design: .rounded))

            if browseStore.recentQueries.isEmpty {
                BrowseEmptyState(
                    icon: "clock.arrow.circlepath",
                    title: "No recent searches",
                    subtitle: "Start typing to search across your media."
                )
            } else {
                VStack(spacing: 10) {
                    ForEach(browseStore.recentQueries, id: \.self) { query in
                        HStack {
                            Button {
                                browseStore.updateSearch(text: query)
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "clock")
                                    Text(query)
                                    Spacer()
                                }
                            }
                            .buttonStyle(.plain)

                            Button {
                                browseStore.removeRecentQuery(query)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(BrowseTheme.secondaryText)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(BrowseTheme.subduedFill)
                        )
                    }
                }
            }
        }
    }
}

private struct BrowseSearchSection: View {
    let title: String
    let items: [BrowseItem]
    let onSelectItem: (BrowseItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.system(size: 22, weight: .bold, design: .rounded))
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(items, id: \.id) { item in
                    Button {
                        onSelectItem(item)
                    } label: {
                        BrowseSearchResultRow(item: item)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

private struct BrowseGridView: View {
    let title: String
    let subtitle: String
    let items: [BrowseItem]
    let onSelectItem: (BrowseItem) -> Void

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: LayoutMetrics.gridMinWidth, maximum: LayoutMetrics.gridMaxWidth), spacing: 18)]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                BrowseHeroHeader(
                    eyebrow: title,
                    title: title,
                    subtitle: subtitle,
                    trailing: { EmptyView() }
                )

                if items.isEmpty {
                    BrowseEmptyState(
                        icon: "film.stack",
                        title: "Nothing here yet",
                        subtitle: "This section will fill as you add media or connect Plex."
                    )
                } else {
                    LazyVGrid(columns: columns, spacing: 18) {
                        ForEach(items, id: \.id) { item in
                            Button {
                                onSelectItem(item)
                            } label: {
                                BrowsePosterCard(item: item, compact: false)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 28)
        }
    }
}

private struct FilesHubView: View {
    @EnvironmentObject private var libraryVM: LibraryViewModel
    @ObservedObject var browseStore: BrowseStore
    @ObservedObject var sourcesVM: SourcesViewModel
    let onPlay: (PlaybackItem) -> Void
    let onPlayAll: ([PlaybackItem]) -> Void
    let onOpenLocalItem: (BrowseItem) -> Void
    let onOpenSettings: () -> Void

    @State private var selectedPinnedFolderPath: String?
    @State private var selectedPinnedSourceID: String?
    @State private var selectedPinnedSourceToken: UUID?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                ForEach(BrowseStore.FilesMode.allCases, id: \.self) { mode in
                    Button {
                        browseStore.filesMode = mode
                    } label: {
                        Text(mode.title)
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .foregroundStyle(
                                browseStore.filesMode == mode ? BrowseTheme.primaryText : BrowseTheme.secondaryText
                            )
                            .background(
                                Capsule()
                                    .fill(browseStore.filesMode == mode ? BrowseTheme.accent : BrowseTheme.elevatedFill)
                            )
                    }
                    .buttonStyle(.plain)
                }

                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)

            if browseStore.filesMode == .library {
                LibraryView(
                    browseStore: browseStore,
                    onSelect: { item in
                        if let browseItem = browseStore.browseItem(forLocalPath: item.path) {
                            onOpenLocalItem(browseItem)
                        } else {
                            onPlay(item)
                        }
                    },
                    onPlayAll: onPlayAll,
                    onSettings: onOpenSettings,
                    selectedFolderPath: $selectedPinnedFolderPath
                )
                .environmentObject(libraryVM)
            } else {
                SourceBrowserView(
                    sourcesVM: sourcesVM,
                    onSelect: onPlay,
                    onPlayAll: onPlayAll,
                    onSettings: onOpenSettings,
                    selectedSourceID: selectedPinnedSourceID,
                    selectedSourceToken: selectedPinnedSourceToken
                )
            }
        }
        .onAppear {
            applyPinnedNavigation()
        }
        .onChange(of: browseStore.pinNavigationToken) { _, _ in
            applyPinnedNavigation()
        }
    }

    private func applyPinnedNavigation() {
        if browseStore.filesMode == .library, let folderPath = browseStore.pinnedFolderPath {
            selectedPinnedFolderPath = folderPath
            return
        }

        if browseStore.filesMode == .sources, let sourceID = browseStore.pinnedSourceID {
            selectedPinnedSourceID = sourceID
            selectedPinnedSourceToken = browseStore.pinNavigationToken
        }
    }
}

private struct BrowseShelfView: View {
    let shelf: BrowseShelf
    let onSelectItem: (BrowseItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(shelf.title)
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                    if let subtitle = shelf.subtitle {
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(BrowseTheme.secondaryText)
                    }
                }
                Spacer()
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 18) {
                    ForEach(shelf.items, id: \.id) { item in
                        Button {
                            onSelectItem(item)
                        } label: {
                            BrowsePosterCard(item: item, compact: true)
                                .frame(width: 190)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }
}

private struct BrowseSearchResultRow: View {
    let item: BrowseItem

    private let thumbnailSlotWidth: CGFloat = 160
    private let thumbnailSlotHeight: CGFloat = 114

    private var sourceLabel: String {
        item.sourceName ?? item.source.searchResultLabel
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            horizontalLayout
            verticalLayout
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .background(BrowseCardBackground(cornerRadius: 22))
    }

    private var horizontalLayout: some View {
        HStack(alignment: .center, spacing: 18) {
            thumbnailSlot

            VStack(alignment: .leading, spacing: 12) {
                chipRow
                textBlock
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            chevron
        }
        .frame(minHeight: thumbnailSlotHeight)
    }

    private var verticalLayout: some View {
        VStack(alignment: .leading, spacing: 14) {
            thumbnailSlot
                .frame(maxWidth: .infinity, alignment: .leading)

            chipRow
            textBlock

            HStack {
                Spacer(minLength: 0)
                chevron
            }
        }
    }

    private var thumbnailSlot: some View {
        MediaArtworkView(
            descriptor: .browseItem(item),
            style: .landscapeRow
        )
        .frame(width: thumbnailSlotWidth)
        .frame(width: thumbnailSlotWidth, height: thumbnailSlotHeight, alignment: .leading)
    }

    private var chipRow: some View {
        HStack(spacing: 8) {
            searchChip(item.kind.searchResultLabel)
            searchChip(sourceLabel)
        }
    }

    private func searchChip(_ title: String) -> some View {
        Text(title)
            .font(.caption)
            .fontWeight(.semibold)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(BrowseTheme.elevatedFill, in: Capsule())
            .overlay(
                Capsule()
                    .stroke(BrowseTheme.divider, lineWidth: 1)
            )
    }

    private var textBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.title)
                .font(.system(size: 19, weight: .bold, design: .rounded))
                .multilineTextAlignment(.leading)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            if let subtitle = item.subtitle {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(BrowseTheme.secondaryText)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let metadata = item.metadataLine {
                Text(metadata)
                    .font(.caption)
                    .foregroundStyle(BrowseTheme.tertiaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .foregroundStyle(BrowseTheme.tertiaryText)
    }
}

private struct BrowsePosterCard: View {
    let item: BrowseItem
    let compact: Bool

    private var cardWidth: CGFloat {
        compact ? 190 : 220
    }

    private var artStyle: MediaArtworkSurfaceStyle {
        item.kind == .episode ? .landscapeCard : .posterCard
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            MediaArtworkView(
                descriptor: .browseItem(item),
                style: artStyle
            )
            .frame(width: cardWidth)

            VStack(alignment: .leading, spacing: 5) {
                Text(item.title)
                    .font(.system(size: compact ? 16 : 18, weight: .semibold, design: .rounded))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                if let subtitle = item.subtitle {
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(BrowseTheme.secondaryText)
                        .lineLimit(2)
                }

                if let metadata = item.metadataLine {
                    Text(metadata)
                        .font(.caption)
                        .foregroundStyle(BrowseTheme.tertiaryText)
                        .lineLimit(1)
                }
            }
        }
        .frame(width: cardWidth, alignment: .leading)
    }
}

private struct BrowseHeroHeader<Trailing: View>: View {
    let eyebrow: String
    let title: String
    let subtitle: String
    let trailing: Trailing

    init(eyebrow: String,
         title: String,
         subtitle: String,
         @ViewBuilder trailing: () -> Trailing) {
        self.eyebrow = eyebrow
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(eyebrow.uppercased())
                .font(.caption)
                .fontWeight(.bold)
                .tracking(1.6)
                .foregroundStyle(BrowseTheme.secondaryText)

            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(title)
                        .font(.system(size: 36, weight: .black, design: .rounded))
                        .multilineTextAlignment(.leading)
                    Text(subtitle)
                        .font(.system(size: 16, weight: .medium, design: .rounded))
                        .foregroundStyle(BrowseTheme.secondaryText)
                }

                Spacer(minLength: 16)
                trailing
            }
        }
        .padding(24)
        .background(BrowseCardBackground(cornerRadius: 30))
    }
}

private struct BrowseBackdrop: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    BrowseTheme.backdropTop,
                    BrowseTheme.backdropBottom
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Circle()
                .fill(BrowseTheme.backdropAccentA)
                .frame(width: 460, height: 460)
                .blur(radius: 120)
                .offset(x: -220, y: -260)

            Circle()
                .fill(BrowseTheme.backdropAccentB)
                .frame(width: 520, height: 520)
                .blur(radius: 140)
                .offset(x: 260, y: 340)
        }
    }
}

private struct BrowseEmptyState: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 34))
                .foregroundStyle(BrowseTheme.secondaryText)
            Text(title)
                .font(.system(size: 22, weight: .bold, design: .rounded))
            Text(subtitle)
                .font(.body)
                .foregroundStyle(BrowseTheme.secondaryText)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 42)
        .padding(.horizontal, 18)
        .background(BrowseCardBackground(cornerRadius: 24))
    }
}

private struct HomeCustomizationView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var browseStore: BrowseStore

    var body: some View {
        NavigationStack {
            List {
                Section("Home Shelves") {
                    ForEach(browseStore.homeLayout.shelves) { shelf in
                        Toggle(isOn: Binding(
                            get: { shelf.isVisible },
                            set: { browseStore.setShelfVisibility(shelf.kind, isVisible: $0) }
                        )) {
                            Text(shelf.kind.title)
                        }
                    }
                    .onMove(perform: browseStore.moveShelves)
                }

                Section("Pin Folders") {
                    ForEach(browseStore.availableFolderPins(), id: \.id) { pin in
                        pinToggleRow(pin)
                    }
                }

                Section("Pin Sources") {
                    ForEach(browseStore.availableSourcePins(), id: \.id) { pin in
                        pinToggleRow(pin)
                    }
                }
            }
            .navigationTitle("Customize Home")
            .toolbar {
                #if os(macOS)
                ToolbarItem(placement: .automatic) {
                    EmptyView()
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Done") { dismiss() }
                }
                #else
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
                #endif
            }
        }
    }

    private func pinToggleRow(_ pin: PinnedDestination) -> some View {
        Toggle(isOn: Binding(
            get: { browseStore.isPinned(pin) },
            set: { _ in browseStore.togglePin(pin) }
        )) {
            VStack(alignment: .leading, spacing: 2) {
                Text(pin.title)
                if let subtitle = pin.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(BrowseTheme.secondaryText)
                }
            }
        }
    }
}

private struct BrowseItemDetailView: View {
    let item: BrowseItem
    @ObservedObject var browseStore: BrowseStore
    let onPlay: (PlaybackItem) -> Void
    let onResume: (PlaybackItem) -> Void
    let onOpenItem: (BrowseItem) -> Void

    @State private var detailModel: BrowseDetailModel?
    @State private var isLoading = false

    var body: some View {
        ScrollView {
            if let detailModel {
                VStack(alignment: .leading, spacing: 28) {
                    hero(for: detailModel)
                    metadataBlock(for: detailModel)
                    actionRow(for: detailModel)

                    if let summary = detailModel.summary, !summary.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Synopsis")
                                .font(.system(size: 22, weight: .bold, design: .rounded))
                                .fixedSize(horizontal: false, vertical: true)
                            Text(summary)
                                .foregroundStyle(BrowseTheme.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    ForEach(detailModel.sections, id: \.id) { section in
                        VStack(alignment: .leading, spacing: 12) {
                            Text(section.title)
                                .font(.system(size: 22, weight: .bold, design: .rounded))
                                .fixedSize(horizontal: false, vertical: true)
                            VStack(spacing: 10) {
                                ForEach(section.items, id: \.id) { sectionItem in
                                    BrowseDetailSectionRow(item: sectionItem) {
                                        onOpenItem(sectionItem)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 28)
            } else if isLoading {
                ProgressView()
                    .padding(.top, 48)
                    .frame(maxWidth: .infinity)
            }
        }
        .background(BrowseBackdrop().ignoresSafeArea())
        .task(id: item.id) {
            isLoading = true
            detailModel = await browseStore.detailModel(for: item)
            isLoading = false
        }
        .navigationTitle(item.title)
        #if !os(macOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private func hero(for model: BrowseDetailModel) -> some View {
        let heroShape = RoundedRectangle(cornerRadius: 30, style: .continuous)

        return ViewThatFits(in: .horizontal) {
            heroHorizontalContent(for: model)
            heroVerticalContent(for: model)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .bottomLeading)
        .frame(minHeight: 320, alignment: .bottomLeading)
        .background {
            ZStack {
                heroBackground(for: model)
                LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .center, endPoint: .bottom)
            }
        }
        .clipShape(heroShape)
    }

    private func metadataBlock(for model: BrowseDetailModel) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(model.metadata, id: \.self) { line in
                    Text(line)
                        .font(.footnote)
                        .fontWeight(.semibold)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(BrowseTheme.elevatedFill, in: Capsule())
                }
            }
        }
    }

    private func actionRow(for model: BrowseDetailModel) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                actionButtons(for: model)
            }

            VStack(alignment: .leading, spacing: 12) {
                actionButtons(for: model)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func platformImageView(_ image: PlatformImage,
                                   rendering: MediaArtworkRendering) -> some View {
        #if os(macOS)
        Image(nsImage: image)
            .resizable()
            .aspectRatio(contentMode: rendering.placement.contentMode)
            .padding(rendering.padding)
        #else
        Image(uiImage: image)
            .resizable()
            .aspectRatio(contentMode: rendering.placement.contentMode)
            .padding(rendering.padding)
        #endif
    }

    private func heroBackground(for model: BrowseDetailModel) -> some View {
        let descriptor = MediaArtworkDescriptor.browseItem(model.item)
        let assets = descriptor.orderedAssets(for: .landscapeCard)

        return ArtworkImageSequenceView(
            assets: assets,
            success: { asset, image in
                platformImageView(
                    image,
                    rendering: descriptor.rendering(for: asset, in: .landscapeCard)
                )
            },
            loading: {
                BrowseBackdrop()
            },
            fallback: {
                BrowseBackdrop()
            }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    private func heroHorizontalContent(for model: BrowseDetailModel) -> some View {
        HStack(alignment: .center, spacing: 24) {
            heroPosterPanel(for: model)

            heroTextPanel(for: model)
                .layoutPriority(1)

            Spacer(minLength: 0)
        }
    }

    private func heroVerticalContent(for model: BrowseDetailModel) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            heroPosterPanel(for: model, width: 160)

            heroTextPanel(for: model)
        }
    }

    private func heroTextBlock(for model: BrowseDetailModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.heroTitle)
                .font(.system(size: 34, weight: .black, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            if let subtitle = model.heroSubtitle {
                Text(subtitle)
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.86))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func heroPosterPanel(for model: BrowseDetailModel, width: CGFloat = 180) -> some View {
        MediaArtworkView(
            descriptor: .browseItem(model.item),
            style: .posterCard
        )
        .frame(width: width)
    }

    private func heroTextPanel(for model: BrowseDetailModel) -> some View {
        heroTextBlock(for: model)
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(.black.opacity(0.24))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(.white.opacity(0.06), lineWidth: 1)
            )
    }

    @ViewBuilder
    private func actionButtons(for model: BrowseDetailModel) -> some View {
        let playback = browseStore.playbackItem(for: model.item, sections: model.sections)

        if model.actions.contains(.resume),
           let playback {
            Button {
                onResume(playback)
            } label: {
                Label(browseStore.resumeLabel(for: model.item) ?? "Resume", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
        }

        if model.actions.contains(.play),
           let playback {
            Button {
                let playback = playback.startingFromBeginning()
                if !playback.isPlex {
                    browseStore.markPlaybackRestarted(playback)
                    ResumeStore.clear(path: playback.resumeKey)
                }
                onPlay(playback)
            } label: {
                Label("Play", systemImage: "play.circle.fill")
            }
            .buttonStyle(.bordered)
        }

        Button {
            browseStore.toggleFavorite(model.item)
        } label: {
            Label(
                browseStore.isFavorite(model.item) ? "Favorited" : "Favorite",
                systemImage: browseStore.isFavorite(model.item) ? "heart.fill" : "heart"
            )
        }
        .buttonStyle(.bordered)
    }
}

private struct BrowseDetailSectionRow: View {
    let item: BrowseItem
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ViewThatFits(in: .horizontal) {
                horizontalLayout
                verticalLayout
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 26)
            .padding(.trailing, 20)
            .padding(.vertical, 14)
            .background(BrowseCardBackground(cornerRadius: 18))
        }
        .buttonStyle(.plain)
    }

    private var horizontalLayout: some View {
        HStack(alignment: .center, spacing: 30) {
            thumbnailContent(width: 150)

            HStack(alignment: .center, spacing: 0) {
                textBlock
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(1)

                Spacer(minLength: 20)

                chevron
            }
            .padding(.vertical, 10)
        }
        .frame(minHeight: 122)
    }

    private var verticalLayout: some View {
        VStack(alignment: .leading, spacing: 12) {
            thumbnailContent(width: 150)
                .frame(maxWidth: .infinity, alignment: .leading)

            textBlock
                .padding(.horizontal, 4)

            HStack {
                Spacer(minLength: 0)
                chevron
            }
            .padding(.horizontal, 4)
        }
        .padding(.vertical, 4)
    }

    private var textBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.title)
                .font(.headline)
                .multilineTextAlignment(.leading)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            if let subtitle = item.subtitle {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(BrowseTheme.secondaryText)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let metadata = item.metadataLine {
                Text(metadata)
                    .font(.caption)
                    .foregroundStyle(BrowseTheme.tertiaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }

    private func thumbnailContent(width: CGFloat) -> some View {
        MediaArtworkView(
            descriptor: .browseItem(item),
            style: .landscapeRow
        )
        .frame(width: width)
    }

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .foregroundStyle(BrowseTheme.tertiaryText)
    }
}

private struct SidebarDestinationButton: View {
    let destination: BrowseDestination
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: destination.systemImage)
                    .frame(width: 20)
                Text(destination.title)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .foregroundStyle(isSelected ? BrowseTheme.primaryText : BrowseTheme.secondaryText)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(isSelected ? BrowseTheme.accent : BrowseTheme.subduedFill)
            )
        }
    }
}
