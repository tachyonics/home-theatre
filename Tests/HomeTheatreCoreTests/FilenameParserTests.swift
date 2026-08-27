import XCTest
@testable import HomeTheatreCore

final class FilenameParserTests: XCTestCase {
    func testEpisodeNumberingForms() {
        let cases: [(String, Int, Int, Int?)] = [
            ("Doctor Who S01E01 Rose.mkv", 1, 1, nil),
            ("Doctor Who S05E12-E13 The Pandorica Opens.mkv", 5, 12, 13),
            ("Doctor Who S05E12E13.mkv", 5, 12, 13),
            ("anything_s01e02.ext", 1, 2, nil),
            ("1x02.ext", 1, 2, nil),
            ("Doctor Who S00E01 The Christmas Invasion.mkv", 0, 1, nil),
        ]
        for (name, season, number, end) in cases {
            let parsed = FilenameParser.episodeNumbering(from: name)
            XCTAssertEqual(parsed?.season, season, name)
            XCTAssertEqual(parsed?.number, number, name)
            XCTAssertEqual(parsed?.numberEnd, end, name)
        }
    }

    func testSeasonFolderNames() {
        XCTAssertEqual(FilenameParser.seasonNumber(fromFolderName: "Season 3"), 3)
        XCTAssertEqual(FilenameParser.seasonNumber(fromFolderName: "Season 03"), 3)
        XCTAssertEqual(FilenameParser.seasonNumber(fromFolderName: "Specials"), 0)
        XCTAssertEqual(FilenameParser.seasonNumber(fromFolderName: "Season 0"), 0)
        XCTAssertNil(FilenameParser.seasonNumber(fromFolderName: "behind the scenes"))
    }

    /// Longest match first, so `-deletedscene` is not read as `-deleted`.
    func testSuffixExtras() {
        let parsed = FilenameParser.suffixExtra(fromFilename: "Doctor Who S01E01 Rose-behindthescenes.mkv")
        XCTAssertEqual(parsed?.type, .behindTheScenes)
        XCTAssertEqual(parsed?.ownerStem, "Doctor Who S01E01 Rose")

        XCTAssertEqual(FilenameParser.suffixExtra(fromFilename: "x-deletedscene.mkv")?.type, .deletedScene)
        XCTAssertEqual(FilenameParser.suffixExtra(fromFilename: "x-deleted.mkv")?.type, .deletedScene)
        XCTAssertNil(FilenameParser.suffixExtra(fromFilename: "Doctor Who S01E01 Rose.mkv"))
    }

    func testExtrasFolderNames() {
        XCTAssertEqual(FilenameParser.extrasFolderType(fromFolderName: "behind the scenes"), .behindTheScenes)
        XCTAssertEqual(FilenameParser.extrasFolderType(fromFolderName: "Interviews"), .interview)
        XCTAssertNil(FilenameParser.extrasFolderType(fromFolderName: "Season 1"))
    }
}
