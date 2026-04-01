import XCTest
@testable import PlaiY

private final class MockPlexURLProtocol: URLProtocol {
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

final class PlexCatalogClientTests: XCTestCase {
    private var sourceID: String!

    override func setUp() {
        super.setUp()
        sourceID = "plex-test-\(UUID().uuidString)"
        XCTAssertTrue(KeychainHelper.save(password: "test-token", for: sourceID))
    }

    override func tearDown() {
        if let sourceID {
            KeychainHelper.delete(for: sourceID)
        }
        MockPlexURLProtocol.handler = nil
        sourceID = nil
        super.tearDown()
    }

    func testFetchSnapshotPaginatesAllPlexSectionResults() async {
        let source = makeSourceConfig()
        let client = PlexCatalogClient(session: makeSession())

        MockPlexURLProtocol.handler = { request in
            let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
            switch components.path {
            case "/library/sections":
                return try Self.makeResponse(
                    url: try XCTUnwrap(request.url),
                    json: [
                        "MediaContainer": [
                            "Directory": [
                                ["key": "1", "type": "movie"]
                            ]
                        ]
                    ]
                )

            case "/library/sections/1/all":
                let start = Int(components.queryItems?.first(where: { $0.name == "X-Plex-Container-Start" })?.value ?? "0") ?? 0
                if start == 0 {
                    return try Self.makeResponse(
                        url: try XCTUnwrap(request.url),
                        json: [
                            "MediaContainer": [
                                "totalSize": 121,
                                "Metadata": (0..<120).map { index in
                                    Self.movieMetadata(ratingKey: index + 1, title: "Movie \(index + 1)")
                                }
                            ]
                        ]
                    )
                }

                return try Self.makeResponse(
                    url: try XCTUnwrap(request.url),
                    json: [
                        "MediaContainer": [
                            "totalSize": 121,
                            "Metadata": [
                                Self.movieMetadata(ratingKey: 121, title: "Movie 121")
                            ]
                        ]
                    ]
                )

            default:
                throw URLError(.unsupportedURL)
            }
        }

        let snapshot = await client.fetchSnapshot(sources: [source])

        XCTAssertEqual(snapshot.movies.count, 121)
        XCTAssertEqual(snapshot.movies.first?.title, "Movie 1")
        XCTAssertEqual(snapshot.movies.last?.title, "Movie 99")
        XCTAssertNotNil(snapshot.itemsByID["plex:\(source.id):121"])
    }

    func testFetchSnapshotUsesHierarchicalFieldsForShowProgress() async {
        let source = makeSourceConfig()
        let client = PlexCatalogClient(session: makeSession())

        MockPlexURLProtocol.handler = { request in
            let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
            switch components.path {
            case "/library/sections":
                return try Self.makeResponse(
                    url: try XCTUnwrap(request.url),
                    json: [
                        "MediaContainer": [
                            "Directory": [
                                ["key": "2", "type": "show"]
                            ]
                        ]
                    ]
                )

            case "/library/sections/2/all":
                return try Self.makeResponse(
                    url: try XCTUnwrap(request.url),
                    json: [
                        "MediaContainer": [
                            "totalSize": 2,
                            "Metadata": [
                                Self.showMetadata(ratingKey: 1, title: "Alpha", leafCount: 10, viewedLeafCount: 4),
                                Self.showMetadata(ratingKey: 2, title: "Zulu", leafCount: 3, viewedLeafCount: 3)
                            ]
                        ]
                    ]
                )

            default:
                throw URLError(.unsupportedURL)
            }
        }

        let snapshot = await client.fetchSnapshot(sources: [source])
        let alpha = try? XCTUnwrap(snapshot.shows.first(where: { $0.title == "Alpha" }))
        let zulu = try? XCTUnwrap(snapshot.shows.first(where: { $0.title == "Zulu" }))

        XCTAssertEqual(snapshot.shows.count, 2)
        XCTAssertEqual(alpha?.title, "Alpha")
        XCTAssertEqual(alpha?.progress ?? 0, 0.4, accuracy: 0.0001)
        XCTAssertEqual(alpha?.isWatched, false)
        XCTAssertEqual(snapshot.continueWatching.map(\.title), ["Alpha"])

        XCTAssertEqual(zulu?.title, "Zulu")
        XCTAssertEqual(zulu?.progress ?? 0, 1.0, accuracy: 0.0001)
        XCTAssertEqual(zulu?.isWatched, true)
    }

    private func makeSourceConfig() -> SourceConfig {
        SourceConfig(
            id: sourceID,
            displayName: "Plex Test",
            type: .plex,
            baseURI: "http://127.0.0.1:32400"
        )
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockPlexURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private static func makeResponse(url: URL, json: [String: Any]) throws -> (HTTPURLResponse, Data) {
        let data = try JSONSerialization.data(withJSONObject: json)
        let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
        return (response, data)
    }

    private static func movieMetadata(ratingKey: Int, title: String) -> [String: Any] {
        [
            "type": "movie",
            "ratingKey": "\(ratingKey)",
            "key": "/library/metadata/\(ratingKey)",
            "title": title,
            "duration": 7_200_000,
            "addedAt": 1_700_000_000 + ratingKey
        ]
    }

    private static func showMetadata(ratingKey: Int,
                                     title: String,
                                     leafCount: Int,
                                     viewedLeafCount: Int) -> [String: Any] {
        [
            "type": "show",
            "ratingKey": "\(ratingKey)",
            "key": "/library/metadata/\(ratingKey)",
            "title": title,
            "leafCount": leafCount,
            "viewedLeafCount": viewedLeafCount,
            "addedAt": 1_700_000_000 + ratingKey
        ]
    }
}
