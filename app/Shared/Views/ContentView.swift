import SwiftUI

struct ContentView: View {
    @EnvironmentObject var libraryVM: LibraryViewModel
    @EnvironmentObject var settings: AppSettings
    @StateObject private var playerVM = PlayerViewModel()
    @StateObject private var sourcesVM = SourcesViewModel()
    @StateObject private var playQueue = PlayQueue()

    enum Screen { case library, sources, settings, player }
    @State private var screen: Screen = .library
    @State private var screenBeforePlayer: Screen = .library
    @State private var selectedFilePath: String?
    @State private var didLoadInitialData = false

    var body: some View {
        Group {
            if screen == .player, let path = selectedFilePath {
                playerView(path: path)
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
            selectedFilePath = path
            screenBeforePlayer = screen
            screen = .player
        }
    }

    // MARK: - Player

    private func playerView(path: String) -> some View {
        PlayerView(
            viewModel: playerVM,
            playQueue: playQueue,
            resumePosition: settings.resumePlayback ? ResumeStore.position(for: path) : nil,
            autoplay: settings.autoplayOnOpen,
            onBack: {
                if settings.resumePlayback {
                    ResumeStore.save(
                        path: path,
                        positionUs: playerVM.currentPosition,
                        durationUs: playerVM.duration,
                        title: playerVM.mediaTitle
                    )
                }
                settings.volume = Double(playerVM.volume)
                playerVM.stop()
                playQueue.clear()
                screen = screenBeforePlayer
                selectedFilePath = nil
            },
            onNextTrack: { skipToNext() },
            onPreviousTrack: { skipToPrevious() },
            onJumpToQueueItem: { index in jumpToQueueItem(at: index) }
        )
        .onAppear {
            playerVM.open(path: path, settings: settings,
                          onNextTrack: playQueue.hasNext ? { [self] in skipToNext() } : nil,
                          onPreviousTrack: playQueue.hasPrevious ? { [self] in skipToPrevious() } : nil)
        }
        .onChange(of: playerVM.playbackEnded) { ended in
            if ended {
                handlePlaybackEnded(finishedPath: path)
            }
        }
    }

    private func handlePlaybackEnded(finishedPath: String) {
        // Clear resume for finished file (it was watched to the end)
        if settings.resumePlayback {
            ResumeStore.clear(path: finishedPath)
        }

        if let next = playQueue.advance() {
            // Auto-advance to next track
            playerVM.stop()
            selectedFilePath = next.path
            playerVM.open(path: next.path, settings: settings,
                          onNextTrack: playQueue.hasNext ? { [self] in skipToNext() } : nil,
                          onPreviousTrack: playQueue.hasPrevious ? { [self] in skipToPrevious() } : nil)
            // Silent auto-resume
            if settings.resumePlayback, let resumePos = ResumeStore.position(for: next.path) {
                playerVM.bridge.seek(to: resumePos)
            }
            playerVM.play()
        } else {
            // Queue exhausted or single file -- navigate back
            settings.volume = Double(playerVM.volume)
            playerVM.stop()
            playQueue.clear()
            screen = screenBeforePlayer
            selectedFilePath = nil
        }
    }

    private func skipToNext() {
        guard let current = playQueue.currentItem else { return }
        guard let next = playQueue.advance() else { return }
        if settings.resumePlayback {
            ResumeStore.save(
                path: current.path,
                positionUs: playerVM.currentPosition,
                durationUs: playerVM.duration,
                title: playerVM.mediaTitle
            )
        }
        playerVM.stop()
        selectedFilePath = next.path
        playerVM.open(path: next.path, settings: settings,
                      onNextTrack: playQueue.hasNext ? { [self] in skipToNext() } : nil,
                      onPreviousTrack: playQueue.hasPrevious ? { [self] in skipToPrevious() } : nil)
        if settings.resumePlayback, let resumePos = ResumeStore.position(for: next.path) {
            playerVM.bridge.seek(to: resumePos)
        }
        playerVM.play()
    }

    private func playAllFromSource(_ items: [(path: String, name: String)]) {
        guard !items.isEmpty else { return }
        playQueue.setQueue(items, startIndex: 0)
        selectedFilePath = items[0].path
        screenBeforePlayer = screen
        screen = .player
    }

    private func jumpToQueueItem(at index: Int) {
        guard let current = playQueue.currentItem else { return }
        guard let target = playQueue.jumpTo(index: index) else { return }
        if settings.resumePlayback {
            ResumeStore.save(
                path: current.path,
                positionUs: playerVM.currentPosition,
                durationUs: playerVM.duration,
                title: playerVM.mediaTitle
            )
        }
        playerVM.stop()
        selectedFilePath = target.path
        playerVM.open(path: target.path, settings: settings,
                      onNextTrack: playQueue.hasNext ? { [self] in skipToNext() } : nil,
                      onPreviousTrack: playQueue.hasPrevious ? { [self] in skipToPrevious() } : nil)
        if settings.resumePlayback, let resumePos = ResumeStore.position(for: target.path) {
            playerVM.bridge.seek(to: resumePos)
        }
        playerVM.play()
    }

    private func skipToPrevious() {
        guard let current = playQueue.currentItem else { return }
        guard let prev = playQueue.goBack() else { return }
        if settings.resumePlayback {
            ResumeStore.save(
                path: current.path,
                positionUs: playerVM.currentPosition,
                durationUs: playerVM.duration,
                title: playerVM.mediaTitle
            )
        }
        playerVM.stop()
        selectedFilePath = prev.path
        playerVM.open(path: prev.path, settings: settings,
                      onNextTrack: playQueue.hasNext ? { [self] in skipToNext() } : nil,
                      onPreviousTrack: playQueue.hasPrevious ? { [self] in skipToPrevious() } : nil)
        if settings.resumePlayback, let resumePos = ResumeStore.position(for: prev.path) {
            playerVM.bridge.seek(to: resumePos)
        }
        playerVM.play()
    }

    // MARK: - tvOS TabView

    #if os(tvOS)
    private var tvBrowseView: some View {
        TabView {
            Tab("Sources", systemImage: "network") {
                SourceBrowserView(
                    sourcesVM: sourcesVM,
                    onSelect: { uri in
                        selectedFilePath = uri
                        screenBeforePlayer = screen
                        screen = .player
                    },
                    onPlayAll: { items in playAllFromSource(items) },
                    onSettings: {}
                )
            }

            Tab("Library", systemImage: "film.stack") {
                LibraryView(
                    onSelect: { path in
                        selectedFilePath = path
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
                        onSelect: { uri in
                            selectedFilePath = uri
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
                        onSelect: { path in
                            selectedFilePath = path
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
