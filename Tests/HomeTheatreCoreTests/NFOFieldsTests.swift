import Foundation
import XCTest
@testable import HomeTheatreCore

final class NFOFieldsTests: XCTestCase {
    private func episode(_ xml: String) throws -> Episode {
        let doc = try NFODocument.parse(data: Data(xml.utf8))
        var episode = Episode(file: URL(fileURLWithPath: "/tmp/x.mkv"))
        NFOFields.applyEpisode(doc, to: &episode)
        return episode
    }

    func testIdentityAndDisplayAreIndependent() throws {
        let parsed = try episode("""
        <episodedetails>
          <title>The Christmas Invasion</title>
          <season>0</season>
          <episode>1</episode>
          <displayseason>1</displayseason>
          <displayepisode>14</displayepisode>
          <lockdata>true</lockdata>
        </episodedetails>
        """)

        XCTAssertEqual(parsed.season, 0)
        XCTAssertEqual(parsed.number, 1)
        XCTAssertEqual(parsed.displaySeason, 1)
        XCTAssertEqual(parsed.displayNumber, 14)
        XCTAssertTrue(parsed.locked)
        XCTAssertEqual(parsed.displaySource, .pinned)
    }

    /// Emby's parser discards non-positive ordering values, which is why nothing
    /// can be placed ahead of episode 1 of a display season without renumbering.
    func testNonPositiveOrderingValuesAreDiscarded() throws {
        let parsed = try episode("""
        <episodedetails>
          <season>0</season><episode>1</episode>
          <displayseason>0</displayseason>
          <displayepisode>-3</displayepisode>
        </episodedetails>
        """)

        XCTAssertNil(parsed.displaySeason)
        XCTAssertNil(parsed.displayNumber)
        XCTAssertEqual(parsed.displaySource, .inherited)
    }

    /// `displayseason`, `airsbefore_season` and `airsafter_season` all write the
    /// same property, so the last one in document order wins.
    func testAliasingOrderingTagsResolveInDocumentOrder() throws {
        let parsed = try episode("""
        <episodedetails>
          <season>0</season><episode>2</episode>
          <airsbefore_season>3</airsbefore_season>
          <displayseason>5</displayseason>
        </episodedetails>
        """)
        XCTAssertEqual(parsed.displaySeason, 5)

        let reversed = try episode("""
        <episodedetails>
          <season>0</season><episode>2</episode>
          <displayseason>5</displayseason>
          <airsbefore_season>3</airsbefore_season>
        </episodedetails>
        """)
        XCTAssertEqual(reversed.displaySeason, 3)
    }

    func testAirsBeforeEpisodeWritesTheSortIndex() throws {
        let parsed = try episode("""
        <episodedetails>
          <season>0</season><episode>4</episode>
          <airsafter_season>4</airsafter_season>
          <airsbefore_episode>7</airsbefore_episode>
        </episodedetails>
        """)
        XCTAssertEqual(parsed.displaySeason, 4)
        XCTAssertEqual(parsed.displayNumber, 7)
    }

    func testMultiPartEpisodeNumberEnd() throws {
        let parsed = try episode("""
        <episodedetails>
          <season>5</season><episode>12</episode><episodenumberend>13</episodenumberend>
        </episodedetails>
        """)
        XCTAssertEqual(parsed.numberEnd, 13)
        XCTAssertEqual(parsed.identityLabel, "S05E12-E13")
    }

    func testUnknownElementsSurviveTheParse() throws {
        let doc = try NFODocument.parse(data: Data("""
        <episodedetails>
          <season>1</season>
          <somethingEmbyWrote>keep me</somethingEmbyWrote>
        </episodedetails>
        """.utf8))

        XCTAssertEqual(doc.root.string("somethingEmbyWrote"), "keep me")
    }

    func testSeriesDisplayOrderIsCaseInsensitive() throws {
        let doc = try NFODocument.parse(data: Data("<tvshow><displayorder>DVD</displayorder><tvdbid>78804</tvdbid></tvshow>".utf8))
        var series = Series(name: "x", folder: URL(fileURLWithPath: "/tmp"))
        NFOFields.applySeries(doc, to: &series)

        XCTAssertEqual(series.displayOrder, .dvd)
        XCTAssertEqual(series.providerIds["Tvdb"], "78804")
    }
}
