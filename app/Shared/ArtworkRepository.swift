import CryptoKit
import Foundation
import SwiftUI

final class ArtworkImageBox: @unchecked Sendable {
    let image: PlatformImage

    init(image: PlatformImage) {
        self.image = image
    }
}

actor ArtworkRepository {
    static let shared = ArtworkRepository()

    private let session: URLSession
    private let cacheDirectoryURL: URL
    private let maxDiskEntryCount: Int
    private let maxDiskSizeBytes: Int64
    private let ignoredQueryItems: Set<String>
    private let memoryCache = NSCache<NSString, ArtworkImageBox>()
    private var inFlightRemoteLoads: [String: Task<ArtworkImageBox?, Never>] = [:]

    init(session: URLSession = ArtworkRepository.makeDefaultSession(),
         cacheDirectoryURL: URL? = nil,
         maxMemoryEntries: Int = 256,
         maxDiskEntryCount: Int = 2_000,
         maxDiskSizeBytes: Int64 = 512 * 1_024 * 1_024,
         ignoredQueryItems: Set<String> = ["x-plex-token"]) {
        self.session = session
        self.cacheDirectoryURL = cacheDirectoryURL ?? Self.defaultCacheDirectory()
        self.maxDiskEntryCount = maxDiskEntryCount
        self.maxDiskSizeBytes = maxDiskSizeBytes
        self.ignoredQueryItems = ignoredQueryItems
        memoryCache.countLimit = maxMemoryEntries
    }

    func image(for asset: MediaArtworkAsset) async -> ArtworkImageBox? {
        switch asset {
        case let .local(_, path):
            return loadLocalImage(path: path)
        case let .remote(_, url):
            return await loadRemoteImage(url: url)
        }
    }

    func removeAllMemoryCachedImages() {
        memoryCache.removeAllObjects()
    }

    static func canonicalRemoteCacheKey(for url: URL,
                                        ignoredQueryItems: Set<String> = ["x-plex-token"]) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return "remote|\(url.absoluteString)"
        }

        let filteredItems = (components.queryItems ?? [])
            .filter { !ignoredQueryItems.contains($0.name.lowercased()) }
            .sorted { lhs, rhs in
                if lhs.name != rhs.name {
                    return lhs.name < rhs.name
                }
                return (lhs.value ?? "") < (rhs.value ?? "")
            }

        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        components.fragment = nil
        components.queryItems = filteredItems.isEmpty ? nil : filteredItems
        return "remote|\(components.string ?? url.absoluteString)"
    }

    private func loadLocalImage(path: String) -> ArtworkImageBox? {
        let cacheKey = Self.localCacheKey(for: path)
        let key = cacheKey as NSString
        if let cached = memoryCache.object(forKey: key) {
            return cached
        }

        guard let image = PlatformImage(contentsOfFile: path) else {
            return nil
        }

        let box = ArtworkImageBox(image: image)
        memoryCache.setObject(box, forKey: key)
        return box
    }

    private func loadRemoteImage(url: URL) async -> ArtworkImageBox? {
        let cacheKey = Self.canonicalRemoteCacheKey(for: url, ignoredQueryItems: ignoredQueryItems)
        let key = cacheKey as NSString
        if let cached = memoryCache.object(forKey: key) {
            return cached
        }

        if let task = inFlightRemoteLoads[cacheKey] {
            return await task.value
        }

        let session = self.session
        let cacheDirectoryURL = self.cacheDirectoryURL
        let maxDiskEntryCount = self.maxDiskEntryCount
        let maxDiskSizeBytes = self.maxDiskSizeBytes
        let task = Task<ArtworkImageBox?, Never> {
            let diskURL = Self.diskCacheURL(for: cacheKey, in: cacheDirectoryURL)
            if let cached = Self.loadRemoteImageFromDisk(at: diskURL) {
                return cached
            }
            return await Self.fetchRemoteImage(
                from: url,
                diskURL: diskURL,
                session: session,
                cacheDirectoryURL: cacheDirectoryURL,
                maxDiskEntryCount: maxDiskEntryCount,
                maxDiskSizeBytes: maxDiskSizeBytes
            )
        }

        inFlightRemoteLoads[cacheKey] = task
        let result = await task.value
        inFlightRemoteLoads[cacheKey] = nil

        if let result {
            memoryCache.setObject(result, forKey: key)
        }
        return result
    }

    private static func fetchRemoteImage(from url: URL,
                                         diskURL: URL,
                                         session: URLSession,
                                         cacheDirectoryURL: URL,
                                         maxDiskEntryCount: Int,
                                         maxDiskSizeBytes: Int64) async -> ArtworkImageBox? {
        let request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 20
        )

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let image = makeImage(from: data) else {
                return nil
            }

            persistRemoteImageData(data, at: diskURL)
            pruneDiskCache(
                at: cacheDirectoryURL,
                maxDiskEntryCount: maxDiskEntryCount,
                maxDiskSizeBytes: maxDiskSizeBytes
            )
            return ArtworkImageBox(image: image)
        } catch {
            return nil
        }
    }

    private static func loadRemoteImageFromDisk(at url: URL) -> ArtworkImageBox? {
        guard let data = try? Data(contentsOf: url),
              let image = makeImage(from: data) else {
            if FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.removeItem(at: url)
            }
            return nil
        }

        touchFile(at: url)
        return ArtworkImageBox(image: image)
    }

    private static func persistRemoteImageData(_ data: Data, at url: URL) {
        let directory = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: nil
            )
            try data.write(to: url, options: .atomic)
        } catch {
            return
        }
    }

    private static func pruneDiskCache(at directoryURL: URL,
                                       maxDiskEntryCount: Int,
                                       maxDiskSizeBytes: Int64) {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [
                .contentModificationDateKey,
                .fileSizeKey,
                .isRegularFileKey
            ],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        let entries = urls.compactMap { url -> (url: URL, modificationDate: Date, size: Int64)? in
            guard let values = try? url.resourceValues(forKeys: [
                .contentModificationDateKey,
                .fileSizeKey,
                .isRegularFileKey
            ]),
            values.isRegularFile == true else {
                return nil
            }

            return (
                url: url,
                modificationDate: values.contentModificationDate ?? .distantPast,
                size: Int64(values.fileSize ?? 0)
            )
        }

        var totalBytes = entries.reduce(Int64(0)) { $0 + $1.size }
        var overflow = entries.sorted { $0.modificationDate < $1.modificationDate }

        while overflow.count > maxDiskEntryCount || totalBytes > maxDiskSizeBytes {
            let evicted = overflow.removeFirst()
            totalBytes -= evicted.size
            try? FileManager.default.removeItem(at: evicted.url)
        }
    }

    private static func touchFile(at url: URL) {
        try? FileManager.default.setAttributes(
            [.modificationDate: Date()],
            ofItemAtPath: url.path
        )
    }

    private static func makeImage(from data: Data) -> PlatformImage? {
        PlatformImage(data: data)
    }

    private static func localCacheKey(for path: String) -> String {
        let url = URL(fileURLWithPath: path)
        let values = try? url.resourceValues(forKeys: [
            .fileSizeKey,
            .contentModificationDateKey
        ])
        let fileSize = Int64(values?.fileSize ?? -1)
        let modificationTime = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
        return "local|\(path)|\(fileSize)|\(modificationTime)"
    }

    private static func diskCacheURL(for cacheKey: String, in directory: URL) -> URL {
        directory.appendingPathComponent(sha256(cacheKey)).appendingPathExtension("img")
    }

    private static func sha256(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func defaultCacheDirectory() -> URL {
        let baseURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return baseURL
            .appendingPathComponent("PlaiY", isDirectory: true)
            .appendingPathComponent("artwork", isDirectory: true)
            .appendingPathComponent("v1", isDirectory: true)
    }

    private static func makeDefaultSession() -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 20
        return URLSession(configuration: configuration)
    }
}

struct ArtworkResolvedAsset {
    let asset: MediaArtworkAsset
    let image: PlatformImage
}

@MainActor
final class ArtworkSequenceLoader: ObservableObject {
    enum Phase {
        case idle
        case loading
        case success(ArtworkResolvedAsset)
        case failure
    }

    @Published private(set) var phase: Phase = .idle

    private let repository: ArtworkRepository
    private var assets: [MediaArtworkAsset] = []
    private var loadTask: Task<Void, Never>?

    init(repository: ArtworkRepository = .shared) {
        self.repository = repository
    }

    func load(assets: [MediaArtworkAsset]) {
        if self.assets == assets {
            switch phase {
            case .loading, .success:
                return
            case .idle, .failure:
                break
            }
        }

        self.assets = assets
        loadTask?.cancel()

        guard !assets.isEmpty else {
            phase = .failure
            return
        }

        phase = .loading
        loadTask = Task { [weak self, repository] in
            for asset in assets {
                guard !Task.isCancelled else { return }
                if let box = await repository.image(for: asset) {
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        guard let self, self.assets == assets else { return }
                        self.phase = .success(ArtworkResolvedAsset(asset: asset, image: box.image))
                    }
                    return
                }
            }

            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.assets == assets else { return }
                self.phase = .failure
            }
        }
    }

    func cancel() {
        loadTask?.cancel()
        loadTask = nil
    }
}

struct ArtworkImageSequenceView<Success: View, Loading: View, Fallback: View>: View {
    let assets: [MediaArtworkAsset]
    private let success: (MediaArtworkAsset, PlatformImage) -> Success
    private let loading: Loading
    private let fallback: Fallback

    @StateObject private var loader: ArtworkSequenceLoader

    init(assets: [MediaArtworkAsset],
         repository: ArtworkRepository = .shared,
         @ViewBuilder success: @escaping (MediaArtworkAsset, PlatformImage) -> Success,
         @ViewBuilder loading: () -> Loading,
         @ViewBuilder fallback: () -> Fallback) {
        self.assets = assets
        self.success = success
        self.loading = loading()
        self.fallback = fallback()
        _loader = StateObject(wrappedValue: ArtworkSequenceLoader(repository: repository))
    }

    var body: some View {
        Group {
            switch loader.phase {
            case let .success(resolved):
                success(resolved.asset, resolved.image)
            case .loading where !assets.isEmpty:
                loading
            case .idle, .failure, .loading:
                fallback
            }
        }
        .task(id: assets) {
            await MainActor.run {
                loader.load(assets: assets)
            }
        }
        .onDisappear {
            loader.cancel()
        }
    }
}
