import SwiftUI

struct ContentView: View {
    @EnvironmentObject var libraryVM: LibraryViewModel
    @EnvironmentObject var settings: AppSettings
    @StateObject private var playerVM = PlayerViewModel()
    @StateObject private var sourcesVM = SourcesViewModel()
    @StateObject private var playQueue = PlayQueue()

    enum Screen { case library, sources, settings, player }
    private enum PlaybackStartAction {
        case openOnly
        case play
        case seekThenPlay(Int64)
    }

    @State private var screen: Screen = .library
    @State private var screenBeforePlayer: Screen = .library
    @State private var selectedPlaybackItem: PlaybackItem?
    @State private var didLoadInitialData = false
    @State private var pendingPlaybackStart: PlaybackStartAction?

    var body: some View {
        Group {
            if screen == .player, let item = selectedPlaybackItem {
                playerView(item: item)
            } else {
                #if os(tvOS)
                tvBrowseView
                #else
                desktopBrowseView
                #endif
            }
        }
        #if os(macOS)
        .frame(minWidth: 800, minHeight: 500)
        #endif
        .onAppear {
            guard !didLoadInitialData else { return }
            didLoadInitialData = true
            libraryVM.restoreSavedFolders()
            sourcesVM.loadSavedSources()
        }
        .onOpenURL { url in
            guard url.scheme == "plaiy", url.host == "play",
                  let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  let path = components.queryItems?.first(where: { $0.name == "path" })?.value
            else { return }
            selectedPlaybackItem = .local(path: path)
            screenBeforePlayer = screen
            screen = .player
        }
    }

    // MARK: - Player

    private func resumePosition(for item: PlaybackItem) -> Int64? {
        guard settings.resumePlayback else { return nil }
        if let plexResume = item.initialResumePositionUs {
            return plexResume
        }
        return ResumeStore.position(for: item.resumeKey)
    }

    private func saveResume(for item: PlaybackItem) {
        guard settings.resumePlayback else { return }
        if item.isPlex && !playerVM.shouldPersistLocalResumeFallback {
            return
        }
        ResumeStore.save(
            path: item.resumeKey,
            positionUs: playerVM.currentPosition,
            durationUs: playerVM.duration,
            title: playerVM.mediaTitle
        )
    }

    private func clearResume(for item: PlaybackItem) {
        guard settings.resumePlayback else { return }
        ResumeStore.clear(path: item.resumeKey)
    }

    private func initialPlaybackStart(for item: PlaybackItem) -> PlaybackStartAction {
        if resumePosition(for: item) != nil {
            return .openOnly
        }
        return settings.autoplayOnOpen ? .play : .openOnly
    }

    private func queuePlaybackStart(for item: PlaybackItem) -> PlaybackStartAction {
        if let resumePos = resumePosition(for: item) {
            return .seekThenPlay(resumePos)
        }
        return .play
    }

    private func startPlayback(for item: PlaybackItem) {
        let start = pendingPlaybackStart ?? initialPlaybackStart(for: item)
        pendingPlaybackStart = nil

        playerVM.open(item: item, settings: settings,
                      onNextTrack: playQueue.hasNext ? { [self] in skipToNext() } : nil,
                      onPreviousTrack: playQueue.hasPrevious ? { [self] in skipToPrevious() } : nil)
        if playerVM.openError != nil { return }

        switch start {
        case .openOnly:
            break
        case .play:
            playerVM.play()
        case .seekThenPlay(let position):
            playerVM.seek(toMicroseconds: position)
            playerVM.play()
        }
    }

    private func transitionToPlayer(item: PlaybackItem, start: PlaybackStartAction? = nil) {
        pendingPlaybackStart = start
        selectedPlaybackItem = item
    }

    private func playerView(item: PlaybackItem) -> some View {
        PlayerView(
            viewModel: playerVM,
            playQueue: playQueue,
            resumePosition: resumePosition(for: item),
            onBack: {
                saveResume(for: item)
                settings.volume = Double(playerVM.volume)
                playerVM.stop()
                playQueue.clear()
                pendingPlaybackStart = nil
                screen = screenBeforePlayer
                selectedPlaybackItem = nil
            },
            onNextTrack: { skipToNext() },
            onPreviousTrack: { skipToPrevious() },
            onJumpToQueueItem: { index in jumpToQueueItem(at: index) }
        )
        .id(item.id)
        .onAppear {
            startPlayback(for: item)
        }
        .onChange(of: playerVM.playbackEnded) { ended in
            if ended {
                handlePlaybackEnded(finishedItem: item)
            }
        }
    }

    private func handlePlaybackEnded(finishedItem: PlaybackItem) {
        clearResume(for: finishedItem)

        if let next = playQueue.advance() {
            playerVM.stop(continuing: true, finished: true)
            transitionToPlayer(item: next.playbackItem, start: queuePlaybackStart(for: next.playbackItem))
        } else {
            settings.volume = Double(playerVM.volume)
            playerVM.stop(finished: true)
            playQueue.clear()
            pendingPlaybackStart = nil
            screen = screenBeforePlayer
            selectedPlaybackItem = nil
        }
    }

    private func skipToNext() {
        guard let current = playQueue.currentItem else { return }
        guard let next = playQueue.advance() else { return }
        saveResume(for: current.playbackItem)
        playerVM.stop(continuing: true)
        transitionToPlayer(item: next.playbackItem, start: queuePlaybackStart(for: next.playbackItem))
    }

    private func playAllFromSource(_ items: [PlaybackItem]) {
        guard !items.isEmpty else { return }
        playQueue.setQueue(items, startIndex: 0)
        selectedPlaybackItem = items[0]
        screenBeforePlayer = screen
        screen = .player
    }

    private func jumpToQueueItem(at index: Int) {
        guard let current = playQueue.currentItem else { return }
        guard let target = playQueue.jumpTo(index: index) else { return }
        saveResume(for: current.playbackItem)
        playerVM.stop(continuing: true)
        transitionToPlayer(item: target.playbackItem, start: queuePlaybackStart(for: target.playbackItem))
    }

    private func skipToPrevious() {
        guard let current = playQueue.currentItem else { return }
        guard let prev = playQueue.goBack() else { return }
        saveResume(for: current.playbackItem)
        playerVM.stop(continuing: true)
        transitionToPlayer(item: prev.playbackItem, start: queuePlaybackStart(for: prev.playbackItem))
    }

    // MARK: - tvOS TabView

    #if os(tvOS)
    private var tvBrowseView: some View {
        TabView {
            Tab("Sources", systemImage: "network") {
                SourceBrowserView(
                    sourcesVM: sourcesVM,
                    onSelect: { item in
                        selectedPlaybackItem = item
                        screenBeforePlayer = screen
                        screen = .player
                    },
                    onPlayAll: { items in playAllFromSource(items) },
                    onSettings: {}
                )
            }

            Tab("Library", systemImage: "film.stack") {
                LibraryView(
                    onSelect: { item in
                        selectedPlaybackItem = item
                        screenBeforePlayer = screen
                        screen = .player
                    },
                    onPlayAll: { items in playAllFromSource(items) },
                    onSettings: {}
                )
                .environmentObject(libraryVM)
            }

            Tab("Settings", systemImage: "gearshape") {
                SettingsView(onDismiss: {})
                    .environmentObject(settings)
                    .environmentObject(libraryVM)
                    .environmentObject(sourcesVM)
            }
        }
    }
    #endif

    // MARK: - Desktop/iOS browse view

    #if !os(tvOS)
    private var desktopBrowseView: some View {
        Group {
            switch screen {
            case .settings:
                SettingsView(onDismiss: { screen = .library })
                    .environmentObject(settings)
                    .environmentObject(libraryVM)
                    .environmentObject(sourcesVM)

            case .sources:
                browseContainer {
                    SourceBrowserView(
                        sourcesVM: sourcesVM,
                        onSelect: { item in
                            selectedPlaybackItem = item
                            screenBeforePlayer = screen
                            screen = .player
                        },
                        onPlayAll: { items in playAllFromSource(items) },
                        onSettings: {
                            screen = .settings
                        }
                    )
                }

            default:
                browseContainer {
                    LibraryView(
                        onSelect: { item in
                            selectedPlaybackItem = item
                            screenBeforePlayer = screen
                            screen = .player
                        },
                        onPlayAll: { items in playAllFromSource(items) },
                        onSettings: {
                            screen = .settings
                        }
                    )
                    .environmentObject(libraryVM)
                }
            }
        }
    }

    private func browseContainer<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            // Tab bar
            HStack(spacing: 0) {
                tabButton("Library", systemImage: "film.stack", screen: .library)
                tabButton("Sources", systemImage: "network", screen: .sources)
            }
            .padding(.horizontal)
            .padding(.top, 4)

            content()
        }
    }

    private func tabButton(_ title: String, systemImage: String, screen target: Screen) -> some View {
        Button {
            screen = target
        } label: {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.caption)
                Text(title)
                    .font(.subheadline)
                    .fontWeight(screen == target ? .semibold : .regular)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .foregroundStyle(screen == target ? .primary : .secondary)
        }
        .buttonStyle(.plain)
    }
    #endif
}
