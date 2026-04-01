import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

struct LibraryView: View {
    @EnvironmentObject var libraryVM: LibraryViewModel
    let onSelect: (PlaybackItem) -> Void
    var onPlayAll: ([PlaybackItem]) -> Void = { _ in }
    let onSettings: () -> Void
    var selectedFolderPath: Binding<String?> = .constant(nil)

    #if os(iOS)
    @State private var showFolderPicker = false
    @State private var showFilePicker = false
    #endif

    private let columns = [
        GridItem(.adaptive(minimum: LayoutMetrics.gridMinWidth,
                           maximum: LayoutMetrics.gridMaxWidth), spacing: 16)
    ]

    private var visibleItems: [LibraryItem] {
        guard let selectedFolder = selectedFolderPath.wrappedValue,
              !selectedFolder.isEmpty else {
            return libraryVM.items
        }
        return libraryVM.items.filter { item in
            itemIsInFolder(item.filePath, folderPath: selectedFolder)
        }
    }

    private var selectedFolderName: String? {
        guard let path = selectedFolderPath.wrappedValue, !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path).lastPathComponent
    }

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

                    if !visibleItems.isEmpty {
                        Button {
                            let items = visibleItems.map {
                                PlaybackItem.local(path: $0.filePath, displayName: $0.title)
                            }
                            onPlayAll(items)
                        } label: {
                            Label("Play All", systemImage: "play.fill")
                        }
                        .buttonStyle(.bordered)
                    }

                    #if !os(tvOS)
                    Button("Add Folder") {
                        pickFolder()
                    }
                    .buttonStyle(.borderedProminent)

                    Button("Open File") {
                        pickFile()
                    }
                    .buttonStyle(.bordered)
                    #endif
                }
                .padding()
            }

            if let selectedFolderName {
                HStack(spacing: 10) {
                    Label("Pinned Folder", systemImage: "pin.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(selectedFolderName)
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Button("Show All") {
                        selectedFolderPath.wrappedValue = nil
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(.horizontal)
                .padding(.vertical, 10)
            }

            if visibleItems.isEmpty {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "film.stack")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    Text(selectedFolderPath.wrappedValue == nil ? "No media files" : "No media in this folder")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    #if os(tvOS)
                    Text("Browse network sources to find media")
                        .foregroundStyle(.tertiary)
                    #else
                    Text(selectedFolderPath.wrappedValue == nil
                         ? "Add a folder or open a file to get started"
                         : "This pinned folder does not contain indexed media right now")
                        .foregroundStyle(.tertiary)
                    #endif
                }
                Spacer()
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(visibleItems) { item in
                            #if os(tvOS)
                            Button {
                                onSelect(PlaybackItem.local(path: item.filePath, displayName: item.title))
                            } label: {
                                MediaItemView(item: item)
                            }
                            .buttonStyle(.card)
                            #else
                            MediaItemView(item: item)
                                .onTapGesture {
                                    onSelect(PlaybackItem.local(path: item.filePath, displayName: item.title))
                                }
                            #endif
                        }
                    }
                    .padding()
                }
            }
        }
        #if os(iOS)
        .fileImporter(isPresented: $showFolderPicker,
                      allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                guard url.startAccessingSecurityScopedResource() else { return }
                libraryVM.addFolder(url)
                url.stopAccessingSecurityScopedResource()
            }
        }
        .fileImporter(isPresented: $showFilePicker,
                      allowedContentTypes: [.movie, .mpeg4Movie, .avi, .mpeg2TransportStream]) { result in
            if case .success(let url) = result {
                guard url.startAccessingSecurityScopedResource() else { return }
                onSelect(PlaybackItem.local(path: url.path))
                url.stopAccessingSecurityScopedResource()
            }
        }
        #endif
    }

    private func pickFolder() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Select a folder containing media files"

        if panel.runModal() == .OK, let url = panel.url {
            libraryVM.addFolder(url)
        }
        #elseif os(iOS)
        showFolderPicker = true
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
            onSelect(PlaybackItem.local(path: url.path))
        }
        #elseif os(iOS)
        showFilePicker = true
        #endif
    }

    private func itemIsInFolder(_ itemPath: String, folderPath: String) -> Bool {
        let normalizedFolder = folderPath.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let normalizedItem = itemPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedFolder.isEmpty else { return true }

        let folderPrefix = "/" + normalizedFolder + "/"
        let exactFolder = "/" + normalizedFolder
        let candidate = normalizedItem.hasPrefix("/") ? normalizedItem : "/" + normalizedItem
        return candidate == exactFolder || candidate.hasPrefix(folderPrefix)
    }
}
