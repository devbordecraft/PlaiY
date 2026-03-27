import SwiftUI

struct ContentView: View {
    @EnvironmentObject var libraryVM: LibraryViewModel
    @EnvironmentObject var settings: AppSettings
    @StateObject private var playerVM = PlayerViewModel()
    @StateObject private var sourcesVM = SourcesViewModel()

    enum Screen { case library, sources, settings, player }
    @State private var screen: Screen = .library
    @State private var selectedFilePath: String?

    var body: some View {
        Group {
            switch screen {
            case .player:
                if let path = selectedFilePath {
                    PlayerView(
                        viewModel: playerVM,
                        resumePosition: settings.resumePlayback ? ResumeStore.position(for: path) : nil,
                        autoplay: settings.autoplayOnOpen,
                        onBack: {
                            if settings.resumePlayback {
                                ResumeStore.save(
                                    path: path,
                                    positionUs: playerVM.currentPosition,
                                    durationUs: playerVM.duration
                                )
                            }
                            settings.volume = Double(playerVM.volume)
                            playerVM.stop()
                            screen = .library
                            selectedFilePath = nil
                        }
                    )
                    .onAppear {
                        playerVM.open(path: path, settings: settings)
                    }
                    .onChange(of: playerVM.playbackEnded) { ended in
                        if ended {
                            if settings.resumePlayback {
                                ResumeStore.clear(path: path)
                            }
                            settings.volume = Double(playerVM.volume)
                            playerVM.stop()
                            screen = .library
                            selectedFilePath = nil
                        }
                    }
                }

            case .settings:
                SettingsView(onDismiss: { screen = .library })
                    .environmentObject(settings)
                    .environmentObject(libraryVM)
                    .environmentObject(sourcesVM)

            case .library:
                browseContainer {
                    LibraryView(
                        onSelect: { path in
                            selectedFilePath = path
                            screen = .player
                        },
                        onSettings: {
                            screen = .settings
                        }
                    )
                    .environmentObject(libraryVM)
                }

            case .sources:
                browseContainer {
                    SourceBrowserView(
                        sourcesVM: sourcesVM,
                        onSelect: { uri in
                            selectedFilePath = uri
                            screen = .player
                        },
                        onSettings: {
                            screen = .settings
                        }
                    )
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 800, minHeight: 500)
        #endif
        .onAppear {
            sourcesVM.loadSavedSources()
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
}
