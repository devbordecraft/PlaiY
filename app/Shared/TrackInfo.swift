import Foundation

struct TrackInfo: Identifiable {
    let streamIndex: Int
    let type: Int // 2=Audio, 3=Subtitle
    let codecName: String
    let language: String
    let title: String
    let isDefault: Bool
    let sampleRate: Int
    let channels: Int
    let subtitleFormat: Int // 0=Unknown, 1=SRT, 2=ASS, 3=PGS, 4=VobSub
    let codecId: Int
    let bitsPerSample: Int

    var id: Int { streamIndex }

    var displayName: String {
        var parts: [String] = []

        // Primary label: title, language name, or fallback
        if !title.isEmpty {
            parts.append(title)
        } else if !language.isEmpty {
            parts.append(Self.languageName(for: language))
        }

        // Codec details
        var details: [String] = []
        let codec = codecName.uppercased()
        if !codec.isEmpty {
            details.append(codec)
        }

        if type == 2 && channels > 0 {
            details.append(Self.channelLabel(channels))
        }

        if type == 2 && bitsPerSample > 0 {
            details.append("\(bitsPerSample)-bit")
        }

        if type == 3 && subtitleFormat > 0 {
            details.append(Self.subtitleFormatName(subtitleFormat))
        }

        if !details.isEmpty {
            parts.append("(\(details.joined(separator: ", ")))")
        }

        if parts.isEmpty {
            return "Track \(streamIndex)"
        }
        return parts.joined(separator: " ")
    }

    static func parseTracks(from json: String) -> (audio: [TrackInfo], subtitle: [TrackInfo]) {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tracks = root["tracks"] as? [[String: Any]] else {
            return ([], [])
        }

        var audio: [TrackInfo] = []
        var subtitle: [TrackInfo] = []

        for t in tracks {
            let type = t["type"] as? Int ?? 0
            guard type == 2 || type == 3 else { continue }

            let info = TrackInfo(
                streamIndex: t["stream_index"] as? Int ?? 0,
                type: type,
                codecName: t["codec_name"] as? String ?? "",
                language: t["language"] as? String ?? "",
                title: t["title"] as? String ?? "",
                isDefault: t["is_default"] as? Bool ?? false,
                sampleRate: t["sample_rate"] as? Int ?? 0,
                channels: t["channels"] as? Int ?? 0,
                subtitleFormat: t["subtitle_format"] as? Int ?? 0,
                codecId: t["codec_id"] as? Int ?? 0,
                bitsPerSample: t["bits_per_sample"] as? Int ?? 0
            )

            if type == 2 {
                audio.append(info)
            } else {
                subtitle.append(info)
            }
        }

        return (audio, subtitle)
    }

    private static func channelLabel(_ channels: Int) -> String {
        switch channels {
        case 1: return "Mono"
        case 2: return "Stereo"
        case 6: return "5.1"
        case 8: return "7.1"
        default: return "\(channels)ch"
        }
    }

    private static func subtitleFormatName(_ format: Int) -> String {
        switch format {
        case 1: return "SRT"
        case 2: return "ASS"
        case 3: return "PGS"
        case 4: return "VobSub"
        default: return ""
        }
    }

    private static func languageName(for code: String) -> String {
        let map: [String: String] = [
            "eng": "English", "en": "English",
            "fra": "French", "fre": "French", "fr": "French",
            "deu": "German", "ger": "German", "de": "German",
            "spa": "Spanish", "es": "Spanish",
            "ita": "Italian", "it": "Italian",
            "por": "Portuguese", "pt": "Portuguese",
            "rus": "Russian", "ru": "Russian",
            "jpn": "Japanese", "ja": "Japanese",
            "kor": "Korean", "ko": "Korean",
            "zho": "Chinese", "chi": "Chinese", "zh": "Chinese",
            "ara": "Arabic", "ar": "Arabic",
            "hin": "Hindi", "hi": "Hindi",
            "tha": "Thai", "th": "Thai",
            "vie": "Vietnamese", "vi": "Vietnamese",
            "nld": "Dutch", "dut": "Dutch", "nl": "Dutch",
            "pol": "Polish", "pl": "Polish",
            "tur": "Turkish", "tr": "Turkish",
            "swe": "Swedish", "sv": "Swedish",
            "nor": "Norwegian", "no": "Norwegian",
            "dan": "Danish", "da": "Danish",
            "fin": "Finnish", "fi": "Finnish",
            "ces": "Czech", "cze": "Czech", "cs": "Czech",
            "hun": "Hungarian", "hu": "Hungarian",
            "ron": "Romanian", "rum": "Romanian", "ro": "Romanian",
            "heb": "Hebrew", "he": "Hebrew",
            "ind": "Indonesian", "id": "Indonesian",
            "msa": "Malay", "may": "Malay", "ms": "Malay",
            "und": "Undetermined",
        ]
        return map[code] ?? code.uppercased()
    }
}
