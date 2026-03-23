import Foundation
import CryptoKit
#if os(macOS)
import AppKit
#endif

class ThumbnailManager {
    static let shared = ThumbnailManager()

    private let cacheDir: URL
    private let queue = OperationQueue()
    private let maxWidth: Int32 = 480
    private let maxHeight: Int32 = 270

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        cacheDir = caches.appendingPathComponent("PlaiY/thumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        queue.maxConcurrentOperationCount = 2
        queue.qualityOfService = .utility
    }

    private func cachePath(for filePath: String) -> URL {
        let hash = SHA256.hash(data: Data(filePath.utf8))
        let hex = hash.prefix(16).map { String(format: "%02x", $0) }.joined()
        return cacheDir.appendingPathComponent(hex + ".jpg")
    }

    func loadThumbnail(for filePath: String) async -> NSImage? {
        let url = cachePath(for: filePath)

        // Check cache
        if FileManager.default.fileExists(atPath: url.path) {
            return NSImage(contentsOf: url)
        }

        // Generate on limited-concurrency queue
        let success = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            queue.addOperation {
                let result = LibraryBridge.generateThumbnail(
                    videoPath: filePath,
                    outputPath: url.path,
                    maxWidth: self.maxWidth,
                    maxHeight: self.maxHeight
                )
                cont.resume(returning: result)
            }
        }

        if success {
            return NSImage(contentsOf: url)
        }
        return nil
    }
}
