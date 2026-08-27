import Foundation
import XCTest
@testable import HomeTheatreCore

/// `season.nfo` lives inside the season folder with root element `<season>` (not
/// `<seasondetails>`), and its `<seasonnumber>` sets the season's index — so it
/// overrides whatever the folder name implied.
final class SeasonNFOTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ht-season-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func touch(_ path: String, contents: String = "") throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
    }

    func testSeasonFieldsAreRead() throws {
        let doc = try NFODocument.parse(data: Data("""
        <season>
          <title>Series One</title>
          <seasonnumber>1</seasonnumber>
          <lockdata>true</lockdata>
          <tvdbid>12345</tvdbid>
        </season>
        """.utf8))

        var season = Season(number: 1, folder: URL(fileURLWithPath: "/tmp"))
        NFOFields.applySeason(doc, to: &season)

        XCTAssertEqual(season.number, 1)
        XCTAssertEqual(season.title, "Series One")
        XCTAssertTrue(season.locked)
        XCTAssertEqual(season.providerIds["Tvdb"], "12345")
    }

    func testSeasonNumberOverridesTheFolderName() throws {
        try touch("Show/Season 1/Show S02E01.mkv")
        try touch("Show/Season 1/season.nfo", contents: "<season><seasonnumber>2</seasonnumber></season>")

        let result = try LibraryScanner().scan(root: root)
        let series = try XCTUnwrap(result.series.first)
        let season = try XCTUnwrap(series.seasons.first)

        XCTAssertEqual(season.number, 2, "season.nfo wins over the folder name")
        XCTAssertEqual(season.folderNumber, 1)
        XCTAssertTrue(season.numberOverriddenByNFO)
        XCTAssertTrue(result.warnings.contains { $0.contains("not 1 per the folder name") })

        let text = LibraryReport().render(result)
        XCTAssertTrue(text.contains("folder says 1, season.nfo says 2"))
    }

    func testFolderNameStandsWhenSeasonNFOAgrees() throws {
        try touch("Show/Season 3/Show S03E01.mkv")
        try touch("Show/Season 3/season.nfo", contents: "<season><title>Series Three</title><seasonnumber>3</seasonnumber></season>")

        let result = try LibraryScanner().scan(root: root)
        let season = try XCTUnwrap(result.series.first?.seasons.first)

        XCTAssertEqual(season.number, 3)
        XCTAssertFalse(season.numberOverriddenByNFO)
        XCTAssertEqual(season.title, "Series Three")
        XCTAssertTrue(LibraryReport().render(result).contains("\"Series Three\""))
    }

    /// Once `<seasonnumber>` is honoured, two folders can land on one season.
    func testCollidingSeasonsAreMergedNotDropped() throws {
        try touch("Show/Season 1/Show S01E01.mkv")
        try touch("Show/Season 2/Show S02E01.mkv")
        try touch("Show/Season 2/season.nfo", contents: "<season><seasonnumber>1</seasonnumber></season>")

        let result = try LibraryScanner().scan(root: root)
        let series = try XCTUnwrap(result.series.first)

        XCTAssertEqual(series.seasons.count, 1)
        XCTAssertEqual(series.seasons.first?.episodes.count, 2)
        XCTAssertTrue(result.warnings.contains { $0.contains("both resolve to season 1; merged") })
    }

    func testMalformedSeasonNFOIsReportedNotFatal() throws {
        try touch("Show/Season 1/Show S01E01.mkv")
        try touch("Show/Season 1/season.nfo", contents: "<season><seasonnumber>1</season>")

        let result = try LibraryScanner().scan(root: root)
        XCTAssertEqual(result.series.first?.seasons.first?.number, 1)
        XCTAssertTrue(result.warnings.contains { $0.contains("season.nfo could not be parsed") })
    }
}
