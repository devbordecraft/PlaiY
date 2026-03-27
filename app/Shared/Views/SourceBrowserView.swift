import SwiftUI

struct SourceBrowserView: View {
    @ObservedObject var sourcesVM: SourcesViewModel
    let onSelect: (String) -> Void
    let onSettings: () -> Void

    @State private var showAddSource = false

    private let columns = [
        GridItem(.adaptive(minimum: LayoutMetrics.gridMinWidth,
                           maximum: LayoutMetrics.gridMaxWidth), spacing: 16)
    ]

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            sourceSelector
            content
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        GlassEffectContainer {
            HStack {
                Text("Sources")
                    .font(.largeTitle)
                    .fontWeight(.bold)

                Spacer()

                Button {
                    onSettings()
                } label: {
                    Image(systemName: "gearshape")
                        .font(.title2)
                }
                .buttonStyle(.bordered)

                Button("Add Source") {
                    showAddSource = true
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
        }
    }

    // MARK: - Source selector

    private var sourceSelector: some View {
        Group {
            if !sourcesVM.sources.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(sourcesVM.sources) { source in
                            sourceChip(source)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                }
            }
        }
    }

    private func sourceChip(_ source: SourceConfig) -> some View {
        let isSelected = sourcesVM.currentSourceId == source.id
        let connected = sourcesVM.isConnected(sourceId: source.id)

        return Button {
            if connected {
                sourcesVM.currentSourceId = source.id
                sourcesVM.navigateToRoot()
            } else {
                sourcesVM.connect(sourceId: source.id)
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: source.type.systemImage)
                    .font(.caption)
                Text(source.displayName)
                    .font(.subheadline)
                    .fontWeight(isSelected ? .semibold : .regular)
                Circle()
                    .fill(connected ? .green : .gray)
                    .frame(width: 6, height: 6)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .glassEffect(isSelected ? .regular.interactive() : .regular, in: .capsule)
        }
        #if os(tvOS)
        .buttonStyle(.bordered)
        #else
        .buttonStyle(.plain)
        .contextMenu {
            Button(connected ? "Disconnect" : "Connect") {
                if connected {
                    sourcesVM.disconnect(sourceId: source.id)
                } else {
                    sourcesVM.connect(sourceId: source.id)
                }
            }
            Button("Remove", role: .destructive) {
                sourcesVM.removeSource(id: source.id)
            }
        }
        #endif
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if sourcesVM.sources.isEmpty {
            emptyState
        } else if sourcesVM.currentSourceId == nil {
            noSourceSelected
        } else if sourcesVM.isConnecting {
            connectingState
        } else {
            directoryListing
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "network")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("No sources configured")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("Add an SMB share or local folder to get started")
                .foregroundStyle(.tertiary)
            Button("Add Source") { showAddSource = true }
                .buttonStyle(.borderedProminent)
            Spacer()
        }
        .sheet(isPresented: $showAddSource) {
            AddSourceView(sourcesVM: sourcesVM) { showAddSource = false }
                .frame(minWidth: 450, minHeight: 350)
        }
    }

    private var noSourceSelected: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "arrow.up.circle")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("Select a source above to browse")
                .foregroundStyle(.secondary)
            Spacer()
        }
        .sheet(isPresented: $showAddSource) {
            AddSourceView(sourcesVM: sourcesVM) { showAddSource = false }
                .frame(minWidth: 450, minHeight: 350)
        }
    }

    private var connectingState: some View {
        VStack(spacing: 12) {
            Spacer()
            ProgressView()
            Text("Connecting...")
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    private var directoryListing: some View {
        VStack(spacing: 0) {
            // Breadcrumb bar
            if !sourcesVM.navigationPath.isEmpty {
                HStack(spacing: 4) {
                    Button {
                        sourcesVM.navigateToRoot()
                    } label: {
                        Image(systemName: "house")
                            .font(.caption)
                    }
                    #if os(tvOS)
                    .buttonStyle(.bordered)
                    #else
                    .buttonStyle(.plain)
                    #endif

                    ForEach(Array(sourcesVM.navigationDisplayNames.enumerated()), id: \.offset) { index, displayName in
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Button(displayName) {
                            let targetPath = Array(sourcesVM.navigationPath.prefix(index + 1))
                            let targetNames = Array(sourcesVM.navigationDisplayNames.prefix(index + 1))
                            sourcesVM.navigationPath = targetPath
                            sourcesVM.navigationDisplayNames = targetNames

                            let isPlex = sourcesVM.sources.first(where: { $0.id == sourcesVM.currentSourceId })?.type == .plex
                            let relativePath = isPlex ? (targetPath.last ?? "") : targetPath.joined(separator: "/")
                            sourcesVM.browse(
                                sourceId: sourcesVM.currentSourceId ?? "",
                                relativePath: relativePath
                            )
                        }
                        #if os(tvOS)
                        .buttonStyle(.bordered)
                        #else
                        .buttonStyle(.plain)
                        #endif
                        .font(.caption)
                    }

                    Spacer()

                    Button {
                        sourcesVM.navigateUp()
                    } label: {
                        Image(systemName: "arrow.up.circle")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(.horizontal)
                .padding(.vertical, 6)
            }

            // Error
            if let error = sourcesVM.error {
                HStack {
                    Image(systemName: "exclamationmark.triangle")
                    Text(error)
                    Spacer()
                    Button("Dismiss") { sourcesVM.error = nil }
                }
                .font(.caption)
                .padding(.horizontal)
                .padding(.vertical, 4)
                .background(.red.opacity(0.1))
            }

            // Loading or entries
            if sourcesVM.isLoading {
                VStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
            } else if sourcesVM.currentEntries.isEmpty {
                VStack {
                    Spacer()
                    Text("Empty folder")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(sourcesVM.currentEntries) { entry in
                            if entry.isDirectory {
                                folderCard(entry)
                            } else {
                                fileCard(entry)
                            }
                        }
                    }
                    .padding()
                }
            }
        }
        .sheet(isPresented: $showAddSource) {
            AddSourceView(sourcesVM: sourcesVM) { showAddSource = false }
                .frame(minWidth: 450, minHeight: 350)
        }
    }

    // MARK: - Entry cards

    private func folderCard(_ entry: SourceEntry) -> some View {
        Button {
            sourcesVM.navigateInto(entry)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.blue.opacity(0.1))
                        .aspectRatio(16.0/9.0, contentMode: .fit)

                    Image(systemName: "folder.fill")
                        .font(.system(size: 36))
                        .foregroundStyle(.blue)
                }

                Text(entry.name)
                    .font(.headline)
                    .lineLimit(2)
            }
            .padding(8)
            #if !os(tvOS)
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 12))
            #endif
        }
        #if os(tvOS)
        .buttonStyle(.card)
        #else
        .buttonStyle(.plain)
        #endif
        #if os(macOS)
        .onHover { hovering in
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        #endif
    }

    private func fileCard(_ entry: SourceEntry) -> some View {
        Button {
            let path = sourcesVM.playablePath(for: entry)
            onSelect(path)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.gray.opacity(0.2))
                        .aspectRatio(16.0/9.0, contentMode: .fit)

                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 36))
                        .foregroundStyle(.white.opacity(0.7))
                }

                Text(entry.name)
                    .font(.headline)
                    .lineLimit(2)

                if !entry.fileSizeText.isEmpty {
                    Text(entry.fileSizeText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(8)
            #if !os(tvOS)
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 12))
            #endif
        }
        #if os(tvOS)
        .buttonStyle(.card)
        #else
        .buttonStyle(.plain)
        #endif
        #if os(macOS)
        .onHover { hovering in
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        #endif
    }
}
