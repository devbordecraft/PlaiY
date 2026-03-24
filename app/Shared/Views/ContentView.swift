import SwiftUI

struct ContentView: View {
    @EnvironmentObject var libraryVM: LibraryViewModel
    @EnvironmentObject var settings: AppSettings
    @StateObject private var playerVM = PlayerViewModel()

    enum Screen { case library, settings, player }
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

            case .library:
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
        }
        #if os(macOS)
        .frame(minWidth: 800, minHeight: 500)
        #endif
    }
}
