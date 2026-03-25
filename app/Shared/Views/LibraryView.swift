import SwiftUI
#if os(macOS)
import AppKit
#endif

struct LibraryView: View {
    @EnvironmentObject var libraryVM: LibraryViewModel
    let onSelect: (String) -> Void
    let onSettings: () -> Void

    private let columns = [
        GridItem(.adaptive(minimum: 200, maximum: 300), spacing: 16)
    ]

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            GlassEffectContainer {
                HStack {
                    Text("Library")
                        .font(.largeTitle)
                        .fontWeight(.bold)

                    Spacer()

                    if libraryVM.isScanning {
                        ProgressView()
                            .scaleEffect(0.8)
                        Text("Scanning...")
                            .foregroundStyle(.secondary)
                    }

                    Button {
                        onSettings()
                    } label: {
                        Image(systemName: "gearshape")
                            .font(.title2)
                    }
                    .buttonStyle(.bordered)

                    Button("Add Folder") {
                        pickFolder()
                    }
                    .buttonStyle(.borderedProminent)

                    Button("Open File") {
                        pickFile()
                    }
                    .buttonStyle(.bordered)
                }
                .padding()
            }

            if libraryVM.items.isEmpty {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "film.stack")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    Text("No media files")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text("Add a folder or open a file to get started")
                        .foregroundStyle(.tertiary)
                }
                Spacer()
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(libraryVM.items) { item in
                            MediaItemView(item: item)
                                .onTapGesture {
                                    onSelect(item.filePath)
                                }
                        }
                    }
                    .padding()
                }
            }
        }
    }

    private func pickFolder() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Select a folder containing media files"

        if panel.runModal() == .OK, let url = panel.url {
            libraryVM.addFolder(url.path)
        }
        #endif
    }

    private func pickFile() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [
            .movie, .mpeg4Movie, .avi, .mpeg2TransportStream
        ]

        if panel.runModal() == .OK, let url = panel.url {
            onSelect(url.path)
        }
        #endif
    }
}
