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

    private static let languageCodes = ["", "eng", "jpn", "fra", "deu", "spa", "ita", "por",
                                         "rus", "kor", "zho", "ara", "hin", "tha", "pol", "tur",
                                         "nld", "swe", "vie"]
    private var languages: [(code: String, name: String)] {
        Self.languageCodes.map { code in
            (code, code.isEmpty ? "None" : TrackInfo.languageName(for: code))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Settings")
                    .font(.largeTitle)
                    .fontWeight(.bold)

                Spacer()

                Button("Done") {
                    onDismiss()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()

            Form {
                generalSection
                audioSection
                subtitleSection
                advancedSection
                librarySection
                sourcesSection
            }
            .formStyle(.grouped)
        }
    }

    // MARK: - Sections

    private var generalSection: some View {
        Section("General") {
            Toggle("Resume Playback", isOn: $settings.resumePlayback)
            Toggle("Autoplay on Open", isOn: $settings.autoplayOnOpen)
        }
    }

    private var audioSection: some View {
        Section("Audio") {
            Picker("Default Language", selection: $settings.preferredAudioLanguage) {
                ForEach(languages, id: \.code) { lang in
                    Text(lang.name).tag(lang.code)
                }
            }

            #if os(macOS)
            Toggle("Send Audio Directly to Receiver", isOn: $settings.audioPassthrough)
            #endif

            Picker("Spatial Audio", selection: $settings.spatialAudioMode) {
                Text("Automatic").tag(0)
                Text("Off").tag(1)
                Text("Always On").tag(2)
            }

            Toggle("Head Tracking", isOn: $settings.headTrackingEnabled)
        }
    }

    private var subtitleSection: some View {
        Section {
            Picker("Default Language", selection: $settings.preferredSubtitleLanguage) {
                ForEach(languages, id: \.code) { lang in
                    Text(lang.name).tag(lang.code)
                }
            }

            Toggle("Show Subtitles Automatically", isOn: $settings.autoSelectSubtitles)

            Picker("Subtitle Size", selection: $settings.subtitleSize) {
                Text("Small").tag(0)
                Text("Medium").tag(1)
                Text("Large").tag(2)
                Text("Very Large").tag(3)
            }

            Picker("Subtitle Color", selection: $settings.subtitleColor) {
                Text("White").tag(0)
                Text("Yellow").tag(1)
            }

            Picker("Subtitle Background", selection: $settings.subtitleBackground) {
                Text("Semi-transparent").tag(0)
                Text("None").tag(1)
                Text("Opaque").tag(2)
            }

            HStack {
                Text("Styled Subtitle Scale")
                Spacer()
                Text(String(format: "%.1fx", settings.styledSubtitleScale))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: $settings.styledSubtitleScale, in: 0.5...2.0, step: 0.1)
        } header: {
            Text("Subtitles")
        } footer: {
            Text("Styled Subtitle Scale adjusts the size of subtitles that have custom formatting (e.g. anime fansubs).")
        }
    }

    private var advancedSection: some View {
        Section {
            Picker("Video Decoder", selection: $settings.hwDecodePref) {
                Text("Automatic").tag(0)
                Text("Hardware Only").tag(1)
                Text("Software Only").tag(2)
            }
        } header: {
            Text("Advanced")
        } footer: {
            Text("These settings are for troubleshooting. Leave them on defaults unless you experience issues.")
        }
    }

    private var librarySection: some View {
        Section("Library") {
            ForEach(Array(libraryVM.folders.enumerated()), id: \.offset) { index, folder in
                HStack {
                    Image(systemName: "folder")
                        .foregroundStyle(.secondary)
                    Text(folder)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button {
                        libraryVM.removeFolder(at: index)
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                }
            }

            #if !os(tvOS)
            Button {
                pickFolder()
            } label: {
                Label("Add Folder", systemImage: "plus")
            }
            #endif
        }
        #if os(iOS)
        .fileImporter(isPresented: $showFolderPicker,
                      allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                guard url.startAccessingSecurityScopedResource() else { return }
                libraryVM.addFolder(url.path)
                url.stopAccessingSecurityScopedResource()
            }
        }
        #endif
    }

    private var sourcesSection: some View {
        Section("Network Sources") {
            ForEach(sourcesVM.sources) { source in
                HStack {
                    Image(systemName: source.type.systemImage)
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading) {
                        Text(source.displayName)
                        Text(source.baseURI)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    Button {
                        sourcesVM.removeSource(id: source.id)
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                }
            }

            if sourcesVM.sources.isEmpty {
                Text("No network sources configured")
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Folder Picker

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
        #elseif os(iOS)
        showFolderPicker = true
        #endif
    }
}
