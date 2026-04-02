import SwiftUI

struct ContentView: View {
    @EnvironmentObject var libraryVM: LibraryViewModel
    @EnvironmentObject var settings: AppSettings
    @StateObject private var playerVM = PlayerViewModel()
    @StateObject private var sourcesVM = SourcesViewModel()
    @StateObject private var playQueue = PlayQueue()
    @StateObject private var browseStore = BrowseStore()

    private enum Screen {
        case browse
        case player
    }

    private enum PlaybackStartAction {
        case openOnly
        case play
        case seekThenPlay(Int64)
    }

    @State private var screen: Screen = .browse
    @State private var selectedPlaybackItem: PlaybackItem?
    @State private var didLoadInitialData = false
    @State private var pendingPlaybackStart: PlaybackStartAction?

    var body: some View {
        Group {
            if screen == .player, let item = selectedPlaybackItem {
                playerView(item: item)
            } else {
                BrowseShellView(
                    sourcesVM: sourcesVM,
                    browseStore: browseStore,
                    onPlay: { item in playPlayback(item) },
                    onResume: { item in resumePlayback(item) },
                    onPlayAll: { items in playAllFromSource(items) }
                )
                .environmentObject(libraryVM)
                .environmentObject(settings)
            }
        }
        #if os(macOS)
        .frame(minWidth: 960, minHeight: 620)
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
                  let path = components.queryItems?.first(where: { $0.name == "path" })?.value else {
                return
            }
            selectedPlaybackItem = .local(path: path)
            pendingPlaybackStart = nil
            screen = .player
        }
    }

    // MARK: - Browse -> Player

    private func playPlayback(_ item: PlaybackItem) {
        pendingPlaybackStart = .play
        selectedPlaybackItem = item
        screen = .player
    }

    private func resumePlayback(_ item: PlaybackItem) {
        if let position = resumePosition(for: item) {
            pendingPlaybackStart = .seekThenPlay(position)
        } else {
            pendingPlaybackStart = .play
        }
        selectedPlaybackItem = item
        screen = .player
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

        playerVM.open(
            item: item,
            settings: settings,
            onNextTrack: playQueue.hasNext ? { [self] in skipToNext() } : nil,
            onPreviousTrack: playQueue.hasPrevious ? { [self] in skipToPrevious() } : nil,
            onPlexAuthInvalid: { sourceId in
                sourcesVM.handlePlexAuthFailure(sourceId: sourceId)
            }
        )
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
                screen = .browse
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
        .onChange(of: playerVM.playbackEnded) { _, ended in
            if ended {
                handlePlaybackEnded(finishedItem: item)
            }
        }
    }

    private func handlePlaybackEnded(finishedItem: PlaybackItem) {
        clearResume(for: finishedItem)
        browseStore.markPlaybackFinished(finishedItem)

        if let next = playQueue.advance() {
            playerVM.stop(continuing: true, finished: true)
            transitionToPlayer(item: next.playbackItem, start: queuePlaybackStart(for: next.playbackItem))
        } else {
            settings.volume = Double(playerVM.volume)
            playerVM.stop(finished: true)
            playQueue.clear()
            pendingPlaybackStart = nil
            screen = .browse
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
        pendingPlaybackStart = queuePlaybackStart(for: items[0])
        selectedPlaybackItem = items[0]
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
}
