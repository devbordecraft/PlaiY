import SwiftUI

@main
struct TestPlayerApp: App {
    @StateObject private var libraryVM = LibraryViewModel()

    init() {
        TPLog.setup()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(libraryVM)
        }
        #if os(macOS)
        .windowStyle(.titleBar)
        .defaultSize(width: 1280, height: 720)
        #endif
    }
}
