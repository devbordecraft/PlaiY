import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var libraryVM: LibraryViewModel
    @EnvironmentObject var sourcesVM: SourcesViewModel
    let onDismiss: () -> Void

    #if os(iOS)
    @State private var showFolderPicker = false
    #endif
    @State private var reconnectSource: SourceConfig?

    private static let languageCodes = ["", "eng", "jpn", "fra", "deu", "spa", "ita", "por",
                                        "rus", "kor", "zho", "ara", "hin", "tha", "pol", "tur",
                                        "nld", "swe", "vie"]

    private var languages: [(code: String, name: String)] {
        Self.languageCodes.map { code in
            (code, code.isEmpty ? "None" : TrackInfo.languageName(for: code))
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                hero
                generalSection
                audioSection
                subtitleSection
                advancedSection
                librarySection
                sourcesSection
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.vertical, 28)
        }
        .sheet(item: $reconnectSource) { source in
            AddSourceView(sourcesVM: sourcesVM, reconnectSource: source) {
                reconnectSource = nil
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
        #endif
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("SETTINGS")
                .font(.caption)
                .fontWeight(.bold)
                .tracking(1.6)
                .foregroundStyle(BrowseTheme.secondaryText)

            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Tune playback, subtitles, and sources for your setup.")
                        .font(.system(size: 36, weight: .black, design: .rounded))
                        .multilineTextAlignment(.leading)
                    Text("Playback defaults, audio routing, subtitle behavior, and library management in one browse-native settings page.")
                        .font(.system(size: 16, weight: .medium, design: .rounded))
                        .foregroundStyle(BrowseTheme.secondaryText)
                }

                Spacer(minLength: 16)

                Button("Done") {
                    onDismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(BrowseCardBackground(cornerRadius: 30))
    }

    private var generalSection: some View {
        SettingsSectionCard(title: "General") {
            SettingsRow {
                Toggle("Resume Playback", isOn: $settings.resumePlayback)
            }
            BrowseDivider()
            SettingsRow {
                Toggle("Autoplay on Open", isOn: $settings.autoplayOnOpen)
            }
            BrowseDivider()
            SettingsRow {
                Picker("Plex Buffer", selection: $settings.plexBufferModeValue) {
                    ForEach(PlexBufferMode.allCases, id: \.rawValue) { mode in
                        Text(mode.title).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.menu)
            }
            BrowseDivider()
            SettingsRow {
                Picker("Plex Buffer Profile", selection: $settings.plexBufferProfileValue) {
                    ForEach(PlexBufferProfile.allCases, id: \.rawValue) { profile in
                        Text(profile.title).tag(profile.rawValue)
                    }
                }
                .pickerStyle(.menu)
            }
        }
    }

    private var audioSection: some View {
        SettingsSectionCard(title: "Audio") {
            SettingsRow {
                Picker("Default Language", selection: $settings.preferredAudioLanguage) {
                    ForEach(languages, id: \.code) { lang in
                        Text(lang.name).tag(lang.code)
                    }
                }
                .pickerStyle(.menu)
            }

            #if os(macOS)
            BrowseDivider()
            SettingsRow {
                Toggle("Send Audio Directly to Receiver", isOn: $settings.audioPassthrough)
            }
            #endif

            BrowseDivider()
            SettingsRow {
                Picker("Spatial Audio", selection: $settings.spatialAudioMode) {
                    Text("Automatic").tag(0)
                    Text("Off").tag(1)
                    Text("Always On").tag(2)
                }
                .pickerStyle(.menu)
            }
            BrowseDivider()
            SettingsRow {
                Toggle("Head Tracking", isOn: $settings.headTrackingEnabled)
            }
        }
    }

    private var subtitleSection: some View {
        SettingsSectionCard(
            title: "Subtitles",
            footnote: "Styled Subtitle Scale adjusts the size of subtitles that have custom formatting (for example anime fansubs)."
        ) {
            SettingsRow {
                Picker("Default Language", selection: $settings.preferredSubtitleLanguage) {
                    ForEach(languages, id: \.code) { lang in
                        Text(lang.name).tag(lang.code)
                    }
                }
                .pickerStyle(.menu)
            }
            BrowseDivider()
            SettingsRow {
                Toggle("Show Subtitles Automatically", isOn: $settings.autoSelectSubtitles)
            }
            BrowseDivider()
            SettingsRow {
                Picker("Subtitle Size", selection: $settings.subtitleSize) {
                    Text("Small").tag(0)
                    Text("Medium").tag(1)
                    Text("Large").tag(2)
                    Text("Very Large").tag(3)
                }
                .pickerStyle(.menu)
            }
            BrowseDivider()
            SettingsRow {
                Picker("Subtitle Color", selection: $settings.subtitleColor) {
                    Text("White").tag(0)
                    Text("Yellow").tag(1)
                }
                .pickerStyle(.menu)
            }
            BrowseDivider()
            SettingsRow {
                Picker("Subtitle Background", selection: $settings.subtitleBackground) {
                    Text("Semi-transparent").tag(0)
                    Text("None").tag(1)
                    Text("Opaque").tag(2)
                }
                .pickerStyle(.menu)
            }
            BrowseDivider()
            SettingsRow {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Styled Subtitle Scale")
                        Spacer()
                        Text(String(format: "%.1fx", settings.styledSubtitleScale))
                            .foregroundStyle(BrowseTheme.secondaryText)
                            .monospacedDigit()
                    }
                    Slider(value: $settings.styledSubtitleScale, in: 0.5...2.0, step: 0.1)
                }
            }
        }
    }

    private var advancedSection: some View {
        SettingsSectionCard(
            title: "Advanced",
            footnote: "These settings are for troubleshooting. Leave them on defaults unless you experience issues."
        ) {
            SettingsRow {
                Picker("Video Decoder", selection: $settings.hwDecodePref) {
                    Text("Automatic").tag(0)
                    Text("Hardware Only").tag(1)
                    Text("Software Only").tag(2)
                }
                .pickerStyle(.menu)
            }
        }
    }

    private var librarySection: some View {
        SettingsSectionCard(title: "Library") {
            if libraryVM.folders.isEmpty {
                SettingsRow {
                    Text("No library folders added yet.")
                        .foregroundStyle(BrowseTheme.secondaryText)
                }
            } else {
                ForEach(Array(libraryVM.folders.enumerated()), id: \.offset) { index, folder in
                    if index > 0 {
                        BrowseDivider()
                    }
                    SettingsRow {
                        HStack(spacing: 12) {
                            Image(systemName: "folder.fill")
                                .foregroundStyle(BrowseTheme.secondaryText)

                            Text(folder)
                                .lineLimit(1)
                                .truncationMode(.middle)

                            Spacer()

                            Button {
                                libraryVM.removeFolder(at: index)
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(BrowseTheme.destructive)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            #if !os(tvOS)
            BrowseDivider()
            SettingsRow {
                HStack {
                    Button {
                        pickFolder()
                    } label: {
                        Label("Add Folder", systemImage: "plus")
                    }
                    .buttonStyle(.bordered)

                    Spacer()
                }
            }
            #endif
        }
    }

    private var sourcesSection: some View {
        SettingsSectionCard(title: "Network Sources") {
            if sourcesVM.sources.isEmpty {
                SettingsRow {
                    Text("No network sources configured.")
                        .foregroundStyle(BrowseTheme.secondaryText)
                }
            } else {
                ForEach(Array(sourcesVM.sources.enumerated()), id: \.element.id) { index, source in
                    let needsReconnect = sourcesVM.needsReconnect(sourceId: source.id)
                    if index > 0 {
                        BrowseDivider()
                    }
                    SettingsRow {
                        HStack(spacing: 12) {
                            Image(systemName: source.type.systemImage)
                                .foregroundStyle(BrowseTheme.secondaryText)

                            VStack(alignment: .leading, spacing: 4) {
                                Text(source.displayName)
                                Text(source.baseURI)
                                    .font(.caption)
                                    .foregroundStyle(BrowseTheme.tertiaryText)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                if needsReconnect {
                                    Text(sourcesVM.reconnectMessage(sourceId: source.id) ?? "Reconnect required")
                                        .font(.caption)
                                        .foregroundStyle(.orange)
                                }
                            }

                            Spacer()

                            if source.type == .plex && needsReconnect {
                                Button("Reconnect") {
                                    reconnectSource = source
                                }
                                .buttonStyle(.bordered)
                            }

                            Button {
                                sourcesVM.removeSource(id: source.id)
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(BrowseTheme.destructive)
                            }
                            .buttonStyle(.plain)
                        }
                    }
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
            libraryVM.addFolder(url)
        }
        #elseif os(iOS)
        showFolderPicker = true
        #endif
    }
}

private struct SettingsSectionCard<Content: View>: View {
    let title: String
    let footnote: String?
    let content: Content

    init(title: String, footnote: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.footnote = footnote
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(BrowseTheme.primaryText)

            VStack(spacing: 0) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(BrowseCardBackground(cornerRadius: 24))

            if let footnote {
                Text(footnote)
                    .font(.footnote)
                    .foregroundStyle(BrowseTheme.tertiaryText)
                    .padding(.horizontal, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SettingsRow<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
