import Foundation

struct LibraryItem: Identifiable, Codable {
    var id: String { filePath }

    let filePath: String
    let title: String
    let durationUs: Int64
    let videoWidth: Int
    let videoHeight: Int
    let videoCodec: String
    let audioCodec: String
    let hdrType: Int
    let fileSize: Int64

    enum CodingKeys: String, CodingKey {
        case filePath = "file_path"
        case title
        case durationUs = "duration_us"
        case videoWidth = "video_width"
        case videoHeight = "video_height"
        case videoCodec = "video_codec"
        case audioCodec = "audio_codec"
        case hdrType = "hdr_type"
        case fileSize = "file_size"
    }

    var durationText: String {
        let totalSeconds = Int(durationUs / 1_000_000)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    var resolutionText: String {
        guard videoWidth > 0, videoHeight > 0 else { return "" }
        if videoHeight >= 2160 { return "4K" }
        if videoHeight >= 1080 { return "1080p" }
        if videoHeight >= 720 { return "720p" }
        return "\(videoWidth)x\(videoHeight)"
    }

    var hdrText: String {
        switch hdrType {
        case 1: return "HDR10"
        case 2: return "HDR10+"
        case 3: return "HLG"
        case 4: return "DV"
        default: return ""
        }
    }

    var fileSizeText: String {
        let gb = Double(fileSize) / 1_073_741_824.0
        if gb >= 1.0 {
            return String(format: "%.1f GB", gb)
        }
        let mb = Double(fileSize) / 1_048_576.0
        return String(format: "%.0f MB", mb)
    }
}

class LibraryViewModel: ObservableObject {
    @Published var items: [LibraryItem] = []
    @Published var folders: [String] = []
    @Published var isScanning = false

    let bridge = LibraryBridge()

    func addFolder(_ path: String) {
        isScanning = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let success = self.bridge.addFolder(path)
            if success {
                self.refreshItems()
                self.refreshFolders()
            }
            DispatchQueue.main.async {
                self.isScanning = false
            }
        }
    }

    func removeFolder(at index: Int) {
        let _ = bridge.removeFolder(at: Int32(index))
        refreshFolders()
        refreshItems()
    }

    func refreshFolders() {
        let count = bridge.folderCount
        var result: [String] = []
        for i in 0..<count {
            result.append(bridge.folder(at: i))
        }
        DispatchQueue.main.async { [weak self] in
            self?.folders = result
        }
    }

    func refreshItems() {
        let jsonStr = bridge.allItemsJSON()
        guard let data = jsonStr.data(using: .utf8) else { return }

        do {
            let decoded = try JSONDecoder().decode([LibraryItem].self, from: data)
            DispatchQueue.main.async { [weak self] in
                self?.items = decoded
            }
        } catch {
            PYLog.error("Library decode error: \(error)", tag: "Library")
        }
    }
}
