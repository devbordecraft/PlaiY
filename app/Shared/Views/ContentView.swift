import SwiftUI

struct ContentView: View {
    @EnvironmentObject var libraryVM: LibraryViewModel
    @StateObject private var playerVM = PlayerViewModel()
    @State private var isPlayerActive = false
    @State private var selectedFilePath: String?

    var body: some View {
        Group {
            if isPlayerActive, let path = selectedFilePath {
                PlayerView(viewModel: playerVM, onBack: {
                    playerVM.stop()
                    isPlayerActive = false
                    selectedFilePath = nil
                })
                .onAppear {
                    playerVM.open(path: path)
                    playerVM.play()
                }
            } else {
                LibraryView(onSelect: { path in
                    selectedFilePath = path
                    isPlayerActive = true
                })
                .environmentObject(libraryVM)
            }
        }
        #if os(macOS)
        .frame(minWidth: 800, minHeight: 500)
        #endif
    }
}
