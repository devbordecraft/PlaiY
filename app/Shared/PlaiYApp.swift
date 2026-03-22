import SwiftUI

@main
struct PlaiYApp: App {
    @StateObject private var libraryVM = LibraryViewModel()
    @StateObject private var settings = AppSettings()

    init() {
        PYLog.setup()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(libraryVM)
                .environmentObject(settings)
        }
        #if os(macOS)
        .windowStyle(.titleBar)
        .defaultSize(width: 1280, height: 720)
        #endif
    }
}
