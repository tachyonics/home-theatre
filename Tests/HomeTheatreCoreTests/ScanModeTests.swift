import Foundation
import XCTest
@testable import HomeTheatreCore

/// Pointing the tool at one series instead of the library root used to report each
/// `Season NN` folder as a series. The shape is detected instead.
final class ScanModeTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ht-mode-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func touch(_ path: String, contents: String = "") throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
    }

    func testSeriesFolderWithSeasonSubfoldersIsNotReadAsALibrary() throws {
        try touch("Season 01/Show S01E01.mkv")
        try touch("Season 02/Show S02E01.mkv")

        let result = try LibraryScanner().scan(root: root)

        XCTAssertEqual(result.mode, .singleSeries)
        XCTAssertEqual(result.series.count, 1)
        XCTAssertEqual(result.series.first?.seasons.map(\.number), [1, 2])
        XCTAssertFalse(
            result.series.contains { $0.name.hasPrefix("Season") },
            "a season folder must never surface as a series"
        )
    }

    func testTvshowNFOAloneIdentifiesASeriesFolder() throws {
        try touch("tvshow.nfo", contents: "<tvshow><title>Show</title></tvshow>")
        try touch("Season 01/Show S01E01.mkv")

        XCTAssertEqual(try LibraryScanner().scan(root: root).mode, .singleSeries)
    }

    func testLibraryRootIsStillReadAsALibrary() throws {
        try touch("Doctor Who (2005)/Season 01/Doctor Who S01E01.mkv")
        try touch("Fawlty Towers/Season 01/Fawlty Towers S01E01.mkv")

        let result = try LibraryScanner().scan(root: root)

        XCTAssertEqual(result.mode, .library)
        XCTAssertEqual(result.series.map(\.name), ["Doctor Who (2005)", "Fawlty Towers"])
    }

    /// Episodes with no season folder at all should become seasons, not land in
    /// the unassigned bin.
    func testFlatSeriesFolder() throws {
        try touch("Show S01E01.mkv")
        try touch("Show S01E02.mkv")
        try touch("Show S01E02-behindthescenes.mkv")
        try touch("Show S02E01.mkv")
        try touch("Some Documentary.mkv")

        let result = try LibraryScanner().scan(root: root)
        let series = try XCTUnwrap(result.series.first)

        XCTAssertEqual(result.mode, .singleSeries)
        XCTAssertEqual(series.seasons.map(\.number), [1, 2])
        XCTAssertEqual(series.seasons.first?.episodes.count, 2)
        XCTAssertEqual(series.seasons.first?.episodes.last?.extras.count, 1)
        XCTAssertEqual(series.unassigned.map(\.lastPathComponent), ["Some Documentary.mkv"])
    }

    func testReportNamesTheMode() throws {
        try touch("Season 01/Show S01E01.mkv")
        XCTAssertTrue(LibraryReport().render(try LibraryScanner().scan(root: root))
            .contains("Read as: single series folder"))
    }
}
