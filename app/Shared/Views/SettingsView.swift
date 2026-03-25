import SwiftUI
#if os(macOS)
import AppKit
#endif

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var libraryVM: LibraryViewModel
    let onDismiss: () -> Void

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
                videoSection
                audioSection
                subtitleSection
                librarySection
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

    private var videoSection: some View {
        Section("Video") {
            Picker("Decoder", selection: $settings.hwDecodePref) {
                Text("Auto").tag(0)
                Text("Force Hardware").tag(1)
                Text("Force Software").tag(2)
            }
        }
    }

    private var audioSection: some View {
        Section("Audio") {
            Picker("Preferred Language", selection: $settings.preferredAudioLanguage) {
                ForEach(languages, id: \.code) { lang in
                    Text(lang.name).tag(lang.code)
                }
            }

            Toggle("Audio Passthrough", isOn: $settings.audioPassthrough)
        }
    }

    private var subtitleSection: some View {
        Section("Subtitles") {
            Picker("Preferred Language", selection: $settings.preferredSubtitleLanguage) {
                ForEach(languages, id: \.code) { lang in
                    Text(lang.name).tag(lang.code)
                }
            }

            Toggle("Auto-select Subtitles", isOn: $settings.autoSelectSubtitles)

            Picker("SRT Font Size", selection: $settings.srtFontSize) {
                Text("Small").tag(0)
                Text("Medium").tag(1)
                Text("Large").tag(2)
                Text("Very Large").tag(3)
            }

            Picker("SRT Text Color", selection: $settings.srtTextColor) {
                Text("White").tag(0)
                Text("Yellow").tag(1)
            }

            Picker("SRT Background", selection: $settings.srtBackgroundStyle) {
                Text("Semi-transparent").tag(0)
                Text("None").tag(1)
                Text("Opaque").tag(2)
            }

            HStack {
                Text("ASS/SSA Scale")
                Spacer()
                Text(String(format: "%.1fx", settings.assFontScale))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: $settings.assFontScale, in: 0.5...2.0, step: 0.1)
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

            Button {
                pickFolder()
            } label: {
                Label("Add Folder", systemImage: "plus")
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
        #endif
    }
}
