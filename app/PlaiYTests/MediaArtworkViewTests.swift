import XCTest
@testable import PlaiY

final class MediaArtworkViewTests: XCTestCase {
    private var cleanupResumeKeys: [String] = []

    override func tearDown() {
        for key in cleanupResumeKeys {
            ResumeStore.clear(path: key)
        }
        cleanupResumeKeys.removeAll()
        super.tearDown()
    }

    func testPosterCardsPreferPosterAssetsBeforeBackdrops() {
        let descriptor = MediaArtworkDescriptor(
            title: "Ballerina",
            posterPath: "/tmp/poster.jpg",
            posterURL: "https://images.example.com/poster.jpg",
            backdropPath: "/tmp/backdrop.jpg",
            backdropURL: "https://images.example.com/backdrop.jpg"
        )

        let order = descriptor.orderedAssets(for: .posterCard).map(assetSummary)

        XCTAssertEqual(order, [
            "local:poster:/tmp/poster.jpg",
            "remote:poster:https://images.example.com/poster.jpg",
            "local:backdrop:/tmp/backdrop.jpg",
            "remote:backdrop:https://images.example.com/backdrop.jpg"
        ])
    }

    func testLandscapeSurfacesPreferBackdropAndFitPosterFallback() {
        let descriptor = MediaArtworkDescriptor(
            title: "Foundation",
            posterURL: "https://images.example.com/poster.jpg",
            backdropURL: "https://images.example.com/backdrop.jpg"
        )

        let landscapeOrder = descriptor.orderedAssets(for: .landscapeRow).map(assetSummary)
        XCTAssertEqual(landscapeOrder, [
            "remote:backdrop:https://images.example.com/backdrop.jpg",
            "remote:poster:https://images.example.com/poster.jpg"
        ])

        guard landscapeOrder.count == 2 else {
            return XCTFail("Expected two ordered artwork candidates")
        }

        let backdropAsset = descriptor.orderedAssets(for: .landscapeRow)[0]
        let posterAsset = descriptor.orderedAssets(for: .landscapeRow)[1]

        XCTAssertEqual(
            descriptor.rendering(for: backdropAsset, in: .landscapeRow),
            MediaArtworkRendering(placement: .fill, padding: 0)
        )
        XCTAssertEqual(
            descriptor.rendering(for: posterAsset, in: .landscapeRow),
            MediaArtworkRendering(placement: .fit, padding: 8)
        )
    }

    func testLibraryDescriptorUsesBrowseArtworkAndResumeProgress() {
        let path = "/tmp/\(UUID().uuidString)/Alien.1979.mkv"
        cleanupResumeKeys.append(path)

        let libraryItem = LibraryItem(
            filePath: path,
            title: "Alien",
            durationUs: 200_000_000,
            videoWidth: 3840,
            videoHeight: 2160,
            videoCodec: "hevc",
            audioCodec: "aac",
            hdrType: 1,
            fileSize: 1_000
        )
        let browseItem = BrowseItem(
            id: "local:file:\(path)",
            kind: .movie,
            source: .local,
            title: "Alien (1979)",
            subtitle: nil,
            summary: nil,
            metadataLine: nil,
            badge: "HDR10",
            artwork: BrowseArtwork(
                posterPath: "/tmp/alien-poster.jpg",
                posterURL: nil,
                backdropPath: "/tmp/alien-fanart.jpg",
                backdropURL: nil
            ),
            progress: nil,
            isWatched: false,
            sourceName: "Local Library",
            playbackItem: nil,
            filePath: path,
            ratingKey: nil,
            plexKey: nil,
            sourceID: nil,
            sourceTypeRawValue: SourceType.local.rawValue,
            addedAt: nil,
            year: 1979,
            seasonNumber: nil,
            episodeNumber: nil
        )

        ResumeStore.save(path: path, positionUs: 100_000_000, durationUs: libraryItem.durationUs)

        let descriptor = MediaArtworkDescriptor.libraryItem(libraryItem, browseItem: browseItem)

        XCTAssertEqual(descriptor.posterPath, "/tmp/alien-poster.jpg")
        XCTAssertEqual(descriptor.backdropPath, "/tmp/alien-fanart.jpg")
        XCTAssertEqual(descriptor.badge, "HDR10")
        XCTAssertEqual(descriptor.progress ?? 0, 0.5, accuracy: 0.001)
        XCTAssertFalse(descriptor.isWatched)
    }

    func testSourceEntryDescriptorUsesFolderFallbackForLocalDirectories() {
        let descriptor = MediaArtworkDescriptor.sourceEntry(
            SourceEntry(
                name: "Movies",
                uri: "/Volumes/Movies",
                isDirectory: true,
                size: 0,
                plex: nil
            )
        )

        XCTAssertEqual(descriptor.palette, .folder)
        XCTAssertEqual(descriptor.fallbackIconName, "folder.fill")
        XCTAssertTrue(descriptor.orderedAssets(for: .landscapeCard).isEmpty)
    }

    func testArtworkRepositoryReusesDecodedLocalImageInstances() async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("png")
        let cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: path) }
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }

        let pngData = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/aW0AAAAASUVORK5CYII=")
        try XCTUnwrap(pngData).write(to: path)

        let repository = ArtworkRepository(cacheDirectoryURL: cacheDirectory)
        let asset = MediaArtworkAsset.local(source: .poster, path: path.path)
        let firstBox = await repository.image(for: asset)
        let secondBox = await repository.image(for: asset)
        let first = try XCTUnwrap(firstBox).image
        let second = try XCTUnwrap(secondBox).image

        XCTAssertTrue(first === second)
    }

    private func assetSummary(_ asset: MediaArtworkAsset) -> String {
        switch asset {
        case let .local(source, path):
            return "local:\(source.rawValue):\(path)"
        case let .remote(source, url):
            return "remote:\(source.rawValue):\(url.absoluteString)"
        }
    }
}
