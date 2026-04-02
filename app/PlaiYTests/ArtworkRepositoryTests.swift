import Foundation
import XCTest
@testable import PlaiY

private final class MockArtworkURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

final class ArtworkRepositoryTests: XCTestCase {
    override func tearDown() {
        MockArtworkURLProtocol.handler = nil
        super.tearDown()
    }

    func testRepositoryDeduplicatesConcurrentRemoteRequests() async throws {
        let cacheDirectory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }

        let repository = ArtworkRepository(
            session: makeSession(),
            cacheDirectoryURL: cacheDirectory
        )
        let asset = MediaArtworkAsset.remote(
            source: .poster,
            url: try XCTUnwrap(URL(string: "https://images.example.com/poster.png?X-Plex-Token=test-token"))
        )

        let lock = NSLock()
        var requestCount = 0
        MockArtworkURLProtocol.handler = { request in
            lock.lock()
            requestCount += 1
            lock.unlock()

            Thread.sleep(forTimeInterval: 0.05)
            return try Self.makeResponse(url: try XCTUnwrap(request.url), data: try Self.pngData())
        }

        try await withThrowingTaskGroup(of: ArtworkImageBox?.self) { group in
            for _ in 0..<6 {
                group.addTask {
                    await repository.image(for: asset)
                }
            }

            for try await result in group {
                XCTAssertNotNil(result)
            }
        }

        XCTAssertEqual(requestCount, 1)
    }

    func testRepositoryUsesDiskCacheAcrossRepositoryInstances() async throws {
        let cacheDirectory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }

        let session = makeSession()
        let asset = MediaArtworkAsset.remote(
            source: .poster,
            url: try XCTUnwrap(URL(string: "https://images.example.com/poster.png?X-Plex-Token=test-token"))
        )

        let lock = NSLock()
        var requestCount = 0
        MockArtworkURLProtocol.handler = { request in
            lock.lock()
            requestCount += 1
            lock.unlock()
            return try Self.makeResponse(url: try XCTUnwrap(request.url), data: try Self.pngData())
        }

        let firstRepository = ArtworkRepository(session: session, cacheDirectoryURL: cacheDirectory)
        let firstImage = await firstRepository.image(for: asset)
        XCTAssertNotNil(firstImage)

        let secondRepository = ArtworkRepository(session: session, cacheDirectoryURL: cacheDirectory)
        let secondImage = await secondRepository.image(for: asset)
        XCTAssertNotNil(secondImage)

        XCTAssertEqual(requestCount, 1)
    }

    func testRepositoryNormalizesRemoteCacheIdentityAcrossQueryOrderAndTokens() async throws {
        let cacheDirectory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }

        let repository = ArtworkRepository(
            session: makeSession(),
            cacheDirectoryURL: cacheDirectory
        )
        let firstAsset = MediaArtworkAsset.remote(
            source: .poster,
            url: try XCTUnwrap(URL(string: "https://images.example.com/poster.png?height=360&width=240&X-Plex-Token=token-a"))
        )
        let secondAsset = MediaArtworkAsset.remote(
            source: .poster,
            url: try XCTUnwrap(URL(string: "https://images.example.com/poster.png?X-Plex-Token=token-b&width=240&height=360"))
        )

        let lock = NSLock()
        var requestCount = 0
        MockArtworkURLProtocol.handler = { request in
            lock.lock()
            requestCount += 1
            lock.unlock()
            return try Self.makeResponse(url: try XCTUnwrap(request.url), data: try Self.pngData())
        }

        let firstImage = await repository.image(for: firstAsset)
        let secondImage = await repository.image(for: secondAsset)
        XCTAssertNotNil(firstImage)
        XCTAssertNotNil(secondImage)
        XCTAssertEqual(requestCount, 1)
    }

    func testRepositoryInvalidatesLocalImageWhenFileMetadataChanges() async throws {
        let cacheDirectory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }

        let imageURL = cacheDirectory.appendingPathComponent("poster.png")
        try Self.pngData().write(to: imageURL)

        let repository = ArtworkRepository(cacheDirectoryURL: cacheDirectory.appendingPathComponent("remote-cache"))
        let asset = MediaArtworkAsset.local(source: .poster, path: imageURL.path)

        let firstBox = await repository.image(for: asset)
        let secondBox = await repository.image(for: asset)
        let first = try XCTUnwrap(firstBox).image
        let second = try XCTUnwrap(secondBox).image
        XCTAssertTrue(first === second)

        try Self.pngData().write(to: imageURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(5)],
            ofItemAtPath: imageURL.path
        )

        let thirdBox = await repository.image(for: asset)
        let third = try XCTUnwrap(thirdBox).image
        XCTAssertFalse(first === third)
    }

    func testSequenceLoaderFallsBackToLaterAssetAfterRemoteFailure() async throws {
        let cacheDirectory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }

        let repository = ArtworkRepository(
            session: makeSession(),
            cacheDirectoryURL: cacheDirectory
        )
        let failingAsset = MediaArtworkAsset.remote(
            source: .backdrop,
            url: try XCTUnwrap(URL(string: "https://images.example.com/fail.png"))
        )
        let succeedingAsset = MediaArtworkAsset.remote(
            source: .poster,
            url: try XCTUnwrap(URL(string: "https://images.example.com/poster.png"))
        )

        MockArtworkURLProtocol.handler = { request in
            let url = try XCTUnwrap(request.url)
            if url.lastPathComponent == "fail.png" {
                throw URLError(.badServerResponse)
            }
            return try Self.makeResponse(url: url, data: try Self.pngData())
        }

        let loader = await MainActor.run {
            ArtworkSequenceLoader(repository: repository)
        }
        await MainActor.run {
            loader.load(assets: [failingAsset, succeedingAsset])
        }

        let resolvedAsset = try await waitForResolvedAsset(loader)
        XCTAssertEqual(resolvedAsset, succeedingAsset)
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockArtworkURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func makeTemporaryDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: nil
        )
        return directory
    }

    private func waitForResolvedAsset(_ loader: ArtworkSequenceLoader,
                                      timeout: TimeInterval = 1.0) async throws -> MediaArtworkAsset {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            let resolvedAsset = await MainActor.run(resultType: MediaArtworkAsset?.self) {
                if case let .success(resolved) = loader.phase {
                    return resolved.asset
                }
                return nil
            }
            if let resolvedAsset {
                return resolvedAsset
            }

            let failed = await MainActor.run {
                if case .failure = loader.phase {
                    return true
                }
                return false
            }
            if failed {
                XCTFail("Artwork loader failed before reaching a fallback asset")
                throw NSError(domain: "ArtworkRepositoryTests", code: 1)
            }

            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTFail("Timed out waiting for artwork resolution")
        throw NSError(domain: "ArtworkRepositoryTests", code: 2)
    }

    private static func makeResponse(url: URL,
                                     data: Data,
                                     statusCode: Int = 200) throws -> (HTTPURLResponse, Data) {
        let response = try XCTUnwrap(
            HTTPURLResponse(
                url: url,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: ["Content-Type": "image/png"]
            )
        )
        return (response, data)
    }

    private static func pngData() throws -> Data {
        try XCTUnwrap(
            Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/aW0AAAAASUVORK5CYII=")
        )
    }
}
