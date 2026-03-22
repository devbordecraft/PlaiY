import SwiftUI

@main
struct PlaiYApp: App {
    @StateObject private var libraryVM = LibraryViewModel()

    init() {
        PYLog.setup()
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
