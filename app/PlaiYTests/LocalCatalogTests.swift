import XCTest
@testable import PlaiY

private typealias AppLibraryItem = PlaiY.LibraryItem

final class LocalCatalogTests: XCTestCase {
    private var tempDirectory: URL!
    private var resumePaths: [String] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        for path in resumePaths {
            ResumeStore.clear(path: path)
        }
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        try super.tearDownWithError()
    }

    func testBuildTreatsYearTaggedFileAsMovie() throws {
        let movieURL = try makeFile(at: "Movies/Gladiator.2000.2160p.mkv")
        let item = makeLibraryItem(path: movieURL.path, durationUs: 9_300_000_000, hdrType: 1)

        let snapshot = LocalCatalogBuilder.build(items: [item], watchedIDs: [])

        XCTAssertEqual(snapshot.movies.count, 1)
        XCTAssertTrue(snapshot.shows.isEmpty)
        XCTAssertEqual(snapshot.movies[0].kind, .movie)
        XCTAssertEqual(snapshot.movies[0].title, "Gladiator (2000)")
        XCTAssertEqual(snapshot.movies[0].badge, "HDR10")
        XCTAssertTrue(snapshot.movies[0].metadataLine?.contains("4K") ?? false)
    }

    func testBuildPreservesMovieTitlesContainingReleaseTokenSubstrings() throws {
        let movieURL = try makeFile(at: "Movies/Adventureland.2009.1080p.mkv")
        let item = makeLibraryItem(path: movieURL.path)

        let snapshot = LocalCatalogBuilder.build(items: [item], watchedIDs: [])

        XCTAssertEqual(snapshot.movies.map(\.title), ["Adventureland (2009)"])
    }

    func testBuildGroupsEpisodesIntoShowAndUsesSidecarArtwork() throws {
        let showFolder = tempDirectory.appendingPathComponent("Shows/The Expanse")
        try FileManager.default.createDirectory(at: showFolder, withIntermediateDirectories: true)
        let posterURL = showFolder.appendingPathComponent("poster.jpg")
        let fanartURL = showFolder.appendingPathComponent("fanart.jpg")
        FileManager.default.createFile(atPath: posterURL.path, contents: Data())
        FileManager.default.createFile(atPath: fanartURL.path, contents: Data())

        let episode1 = try makeFile(at: "Shows/The Expanse/Season 1/The.Expanse.S01E01.Dulcinea.mkv")
        let episode2 = try makeFile(at: "Shows/The Expanse/Season 1/The.Expanse.S01E02.The.Big.Empty.mkv")
        let item1 = makeLibraryItem(path: episode1.path)
        let item2 = makeLibraryItem(path: episode2.path)

        ResumeStore.save(path: episode1.path, positionUs: 60_000_000, durationUs: item1.durationUs)
        resumePaths.append(episode1.path)

        let snapshot = LocalCatalogBuilder.build(items: [item1, item2], watchedIDs: [])

        XCTAssertEqual(snapshot.shows.count, 1)
        XCTAssertEqual(snapshot.shows[0].title, "The Expanse")
        XCTAssertEqual(snapshot.shows[0].subtitle, "2 episodes")
        XCTAssertEqual(snapshot.shows[0].artwork.posterPath, posterURL.path)
        XCTAssertEqual(snapshot.shows[0].artwork.backdropPath, fanartURL.path)
        XCTAssertNotNil(snapshot.shows[0].progress)
        XCTAssertEqual(snapshot.shows[0].progress ?? 0, 0.5, accuracy: 0.001)
        XCTAssertEqual(snapshot.continueWatching.map(\.title), ["Dulcinea"])

        let sections = snapshot.showSections["the-expanse"]
        XCTAssertEqual(sections?.count, 1)
        XCTAssertEqual(sections?.first?.title, "Season 1")
        XCTAssertEqual(sections?.first?.items.map(\.title), ["Dulcinea", "The Big Empty"])
    }

    func testBuildPreservesReleaseTokenSubstringsInShowTitlesEpisodeTitlesAndIDs() throws {
        let episodeURL = try makeFile(at: "Shows/Adventure Time/Season 1/Adventure.Time.S01E01.The.Adventurer.mkv")
        let item = makeLibraryItem(path: episodeURL.path)

        let snapshot = LocalCatalogBuilder.build(items: [item], watchedIDs: [])

        XCTAssertEqual(snapshot.shows.map(\.title), ["Adventure Time"])
        XCTAssertEqual(snapshot.showSections["adventure-time"]?.first?.items.map(\.title), ["The Adventurer"])
    }

    func testBuildMarksShowWatchedWhenAllEpisodesAreWatched() throws {
        let episode = try makeFile(at: "Shows/Dark/Season 1/Dark.S01E01.Secrets.mkv")
        let item = makeLibraryItem(path: episode.path)

        let snapshot = LocalCatalogBuilder.build(
            items: [item],
            watchedIDs: ["local:file:\(episode.path)"]
        )

        XCTAssertEqual(snapshot.shows.count, 1)
        XCTAssertTrue(snapshot.shows[0].isWatched)
        XCTAssertTrue(snapshot.continueWatching.isEmpty)
    }

    func testBuildResolvesShowArtworkFromUnderscoreAndHyphenSeasonFolders() throws {
        let foundationFolder = tempDirectory.appendingPathComponent("Shows/Foundation")
        try FileManager.default.createDirectory(at: foundationFolder, withIntermediateDirectories: true)
        let foundationPoster = foundationFolder.appendingPathComponent("poster.jpg")
        let foundationFanart = foundationFolder.appendingPathComponent("fanart.jpg")
        FileManager.default.createFile(atPath: foundationPoster.path, contents: Data())
        FileManager.default.createFile(atPath: foundationFanart.path, contents: Data())

        let severanceFolder = tempDirectory.appendingPathComponent("Shows/Severance")
        try FileManager.default.createDirectory(at: severanceFolder, withIntermediateDirectories: true)
        let severancePoster = severanceFolder.appendingPathComponent("poster.jpg")
        let severanceFanart = severanceFolder.appendingPathComponent("fanart.jpg")
        FileManager.default.createFile(atPath: severancePoster.path, contents: Data())
        FileManager.default.createFile(atPath: severanceFanart.path, contents: Data())

        let foundationEpisode = try makeFile(at: "Shows/Foundation/Season_1/Foundation.S01E01.The.Emperor's.Peace.mkv")
        let severanceEpisode = try makeFile(at: "Shows/Severance/Season-1/Severance.S01E01.Good.News.About.Hell.mkv")

        let snapshot = LocalCatalogBuilder.build(
            items: [
                makeLibraryItem(path: foundationEpisode.path),
                makeLibraryItem(path: severanceEpisode.path)
            ],
            watchedIDs: []
        )

        let foundation = try XCTUnwrap(snapshot.shows.first(where: { $0.title == "Foundation" }))
        XCTAssertEqual(foundation.artwork.posterPath, foundationPoster.path)
        XCTAssertEqual(foundation.artwork.backdropPath, foundationFanart.path)

        let severance = try XCTUnwrap(snapshot.shows.first(where: { $0.title == "Severance" }))
        XCTAssertEqual(severance.artwork.posterPath, severancePoster.path)
        XCTAssertEqual(severance.artwork.backdropPath, severanceFanart.path)
    }

    private func makeLibraryItem(path: String,
                                 durationUs: Int64 = 120_000_000,
                                 hdrType: Int = 0) -> AppLibraryItem {
        AppLibraryItem(
            filePath: path,
            title: URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent,
            durationUs: durationUs,
            videoWidth: 3840,
            videoHeight: 2160,
            videoCodec: "hevc",
            audioCodec: "eac3",
            hdrType: hdrType,
            fileSize: 0
        )
    }

    @discardableResult
    private func makeFile(at relativePath: String) throws -> URL {
        let url = tempDirectory.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: Data())
        return url
    }
}
