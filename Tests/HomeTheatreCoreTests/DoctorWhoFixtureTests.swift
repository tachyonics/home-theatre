import Foundation
import XCTest
@testable import HomeTheatreCore

/// Builds the awkward shape from the design discussion — specials that belong
/// between seasons, and extras hanging off the series, a season, an episode and a
/// merged two-parter — then checks the scanner reconstructs it.
final class DoctorWhoFixtureTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ht-fixture-\(UUID().uuidString)")
        try buildFixture()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func touch(_ path: String, contents: String = "") throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
    }

    private func buildFixture() throws {
        let series = "Doctor Who (2005) [tvdbid=78804]"

        try touch("\(series)/tvshow.nfo", contents: """
        <tvshow><title>Doctor Who</title><displayorder>aired</displayorder><tvdbid>78804</tvdbid></tvshow>
        """)

        // Series-level extras.
        try touch("\(series)/behind the scenes/Doctor Who Confidential - The Ninth Doctor.mkv")
        try touch("\(series)/interviews/Russell T Davies on the Revival.mkv")

        // Series 1: 13 episodes, one with a suffix extra, one with an episode folder.
        for number in 1...12 {
            try touch("\(series)/Season 1/Doctor Who S01E\(String(format: "%02d", number)).mkv")
        }
        try touch("\(series)/Season 1/Doctor Who S01E01-behindthescenes.mkv")
        try touch("\(series)/Season 1/featurettes/Making Series 1.mkv")
        try touch("\(series)/Season 1/S01E13/Doctor Who S01E13 The Parting of the Ways.mkv")
        try touch("\(series)/Season 1/S01E13/deleted scenes/Unused Dalek Scene.mkv")

        // Series 5 with a merged two-parter carrying its own extra.
        try touch("\(series)/Season 5/Doctor Who S05E12-E13 The Pandorica Opens.mkv")
        try touch("\(series)/Season 5/Doctor Who S05E12-E13 The Pandorica Opens.nfo", contents: """
        <episodedetails>
          <title>The Pandorica Opens</title>
          <season>5</season><episode>12</episode><episodenumberend>13</episodenumberend>
        </episodedetails>
        """)
        try touch("\(series)/Season 5/Doctor Who S05E12-E13 The Pandorica Opens-behindthescenes.mkv")

        // Specials — season 0 identity, displayed at the tail of the preceding season.
        try touch("\(series)/Specials/Doctor Who S00E01 The Christmas Invasion.mkv")
        try touch("\(series)/Specials/Doctor Who S00E01 The Christmas Invasion.nfo", contents: """
        <episodedetails>
          <title>The Christmas Invasion</title>
          <season>0</season><episode>1</episode>
          <displayseason>1</displayseason><displayepisode>14</displayepisode>
          <lockdata>true</lockdata>
        </episodedetails>
        """)
        try touch("\(series)/Specials/Doctor Who S00E01 The Christmas Invasion-behindthescenes.mkv")
        try touch("\(series)/Specials/interviews/David Tennant on Christmas.mkv")

        // Artwork, theme media and subtitles — everything that is neither content
        // nor NFO, including a poster that loses to `folder.jpg` and a theme video
        // that must not be mistaken for a stray episode.
        try touch("\(series)/folder.jpg")
        try touch("\(series)/poster.jpg")
        try touch("\(series)/fanart.jpg")
        try touch("\(series)/theme.mp3")
        try touch("\(series)/backdrops/Title Sequence.mkv")
        try touch("\(series)/season01-poster.jpg")
        try touch("\(series)/season-specials-poster.jpg")
        try touch("\(series)/Season 1/folder.jpg")
        try touch("\(series)/Season 1/Doctor Who S01E01-thumb.jpg")
        try touch("\(series)/Season 1/Doctor Who S01E01.eng.srt")
        try touch("\(series)/Season 1/Doctor Who S01E01.fre.forced.srt")

        // An unplaced file, the raw material for the editor's unassigned bin.
        try touch("\(series)/Some Unlabelled Documentary.mkv")
    }

    func testScanReconstructsTheStructure() throws {
        let result = try LibraryScanner().scan(root: root)
        XCTAssertEqual(result.series.count, 1)
        let series = try XCTUnwrap(result.series.first)

        XCTAssertEqual(series.displayOrder, .aired)
        XCTAssertEqual(series.providerIds["Tvdb"], "78804")
        XCTAssertEqual(series.extras.count, 2)
        XCTAssertEqual(Set(series.extras.map(\.type)), [.behindTheScenes, .interview])
        // Folder-derived extras record where they are filed; suffix-derived ones
        // sit in no extras folder and record nothing.
        XCTAssertEqual(
            Set(series.extras.compactMap(\.folderName)),
            ["behind the scenes", "interviews"]
        )

        // Season 1 holds 13 episodes: 12 loose plus the one in its own folder.
        let seasonOne = try XCTUnwrap(series.seasons.first { $0.number == 1 })
        XCTAssertEqual(seasonOne.episodes.count, 13)
        XCTAssertEqual(seasonOne.extras.count, 1, "only the featurette belongs to the season itself")

        // An extra inside an SxxExx folder belongs to that episode, not the season.
        let thirteenth = try XCTUnwrap(seasonOne.episodes.first { $0.number == 13 })
        XCTAssertEqual(thirteenth.extras.map(\.type), [.deletedScene])

        // The suffix extra binds to its own episode, not the season.
        let first = try XCTUnwrap(seasonOne.episodes.first { $0.number == 1 })
        XCTAssertEqual(first.extras.count, 1)
        XCTAssertEqual(first.extras.first?.type, .behindTheScenes)
        XCTAssertNil(first.extras.first?.folderName, "bound by suffix, so filed in no folder")

        // Merged two-parter keeps its span and carries its extra.
        let seasonFive = try XCTUnwrap(series.seasons.first { $0.number == 5 })
        let twoParter = try XCTUnwrap(seasonFive.episodes.first)
        XCTAssertEqual(twoParter.identityLabel, "S05E12-E13")
        XCTAssertEqual(twoParter.extras.count, 1)

        // `Specials` held SxxExx files, so it is a season and not an extras folder.
        let specials = try XCTUnwrap(series.seasons.first { $0.number == 0 })
        XCTAssertEqual(specials.episodes.count, 1)
        XCTAssertEqual(specials.extras.count, 1, "the interviews folder is a season-0 extra")

        XCTAssertEqual(series.unassigned.map(\.lastPathComponent), ["Some Unlabelled Documentary.mkv"])
    }

    func testSpecialResolvesIntoSeasonOne() throws {
        let result = try LibraryScanner().scan(root: root)
        let resolved = DisplayOrderResolver().resolve(try XCTUnwrap(result.series.first))

        let seasonOne = try XCTUnwrap(resolved.seasons.first { $0.number == 1 })
        XCTAssertEqual(seasonOne.episodes.count, 14, "13 episodes plus the interleaved special")

        let last = try XCTUnwrap(seasonOne.episodes.last)
        XCTAssertEqual(last.episode.title, "The Christmas Invasion")
        XCTAssertEqual(last.effectiveNumber, 14)
        XCTAssertEqual(last.source, .pinned)
        XCTAssertTrue(last.isRelocated, "identity is season 0, display is season 1")

        // Nothing is left behind in the specials bucket.
        XCTAssertNil(resolved.seasons.first { $0.number == 0 })
    }

    /// Episodes with no display numbering keep their identity position.
    func testInheritedEpisodesAreNotPinned() throws {
        let result = try LibraryScanner().scan(root: root)
        let resolved = DisplayOrderResolver().resolve(try XCTUnwrap(result.series.first))
        let seasonOne = try XCTUnwrap(resolved.seasons.first { $0.number == 1 })

        let third = try XCTUnwrap(seasonOne.episodes.first { $0.effectiveNumber == 3 })
        XCTAssertEqual(third.source, .inherited)
        XCTAssertFalse(third.isRelocated)
    }

    func testAssetsAreCollectedAsCapabilities() throws {
        let result = try LibraryScanner().scan(root: root)
        let series = try XCTUnwrap(result.series.first)

        // A theme video lives in a sub-folder of videos, which would otherwise
        // read as unplaced content.
        XCTAssertEqual(series.unassigned.map(\.lastPathComponent), ["Some Unlabelled Documentary.mkv"])

        let seriesEntries = CapabilityInventory.entries(
            level: .series,
            nfoURL: series.nfoURL,
            assets: series.assets
        )
        func entry(_ capability: Capability, _ entries: [CapabilityInventory.Entry]) throws -> CapabilityInventory.Entry {
            try XCTUnwrap(entries.first { $0.capability == capability })
        }

        XCTAssertTrue(try entry(.details, seriesEntries).isPresent)
        XCTAssertEqual(try entry(.poster, seriesEntries).count, 2)
        XCTAssertEqual(try entry(.poster, seriesEntries).shadowedCount, 1, "poster.jpg loses to folder.jpg")
        XCTAssertEqual(try entry(.backdrop, seriesEntries).count, 1)
        XCTAssertEqual(try entry(.themeSong, seriesEntries).countLabel, "1 file")
        XCTAssertEqual(try entry(.themeVideo, seriesEntries).assets.map(\.name), ["Title Sequence.mkv"])
        XCTAssertFalse(try entry(.banner, seriesEntries).isPresent)

        // The season's own folder.jpg wins; the series-folder season01-poster.jpg
        // is kept so the duplication is visible, but marked as unreachable.
        let seasonOne = try XCTUnwrap(series.seasons.first { $0.number == 1 })
        let posters = seasonOne.assets.filter { $0.capability == .poster }
        XCTAssertEqual(posters.map(\.name), ["folder.jpg", "season01-poster.jpg"])
        XCTAssertEqual(posters.map(\.isShadowed), [false, true])
        XCTAssertEqual(posters.last?.locationNote, "in the series folder")

        // A season image can name a season that has a folder of its own or not.
        let specials = try XCTUnwrap(series.seasons.first { $0.number == 0 })
        XCTAssertEqual(specials.assets.map(\.rule), ["season-specials-poster.ext"])

        let first = try XCTUnwrap(seasonOne.episodes.first { $0.number == 1 })
        let episodeEntries = CapabilityInventory.entries(
            level: .episode,
            nfoURL: first.nfoURL,
            assets: first.assets
        )
        XCTAssertEqual(try entry(.thumb, episodeEntries).count, 1)
        XCTAssertEqual(try entry(.subtitles, episodeEntries).count, 2)
        XCTAssertEqual(
            try entry(.subtitles, episodeEntries).assets.compactMap(\.subtitle?.summary),
            ["eng · srt", "fre · forced · srt"]
        )
        XCTAssertFalse(try entry(.details, episodeEntries).isPresent, "this episode has no sidecar")

        // The suffix extra beside it must not be read as one of its subtitles.
        XCTAssertTrue(first.assets.allSatisfy { !$0.name.contains("behindthescenes") })
    }

    func testReportRenders() throws {
        let result = try LibraryScanner().scan(root: root)
        let text = LibraryReport().render(result)

        XCTAssertTrue(text.contains("── Season 1 ── (14)"))
        XCTAssertTrue(text.contains("The Christmas Invasion"))
        XCTAssertTrue(text.contains("moved from S0"))
        XCTAssertTrue(text.contains("Unassigned (1)"))
        XCTAssertTrue(text.contains("Season 1 extras"), "season extras must not read as episode extras")
        XCTAssertTrue(
            text.contains("Specials extras — this season has no episodes left in the display order"),
            "extras on a dissolved season must still be reported"
        )
        XCTAssertTrue(text.contains("David Tennant on Christmas"))
        XCTAssertTrue(text.contains("provides: Poster ×2, Backdrop, Theme Song, Theme Video"))
        XCTAssertTrue(text.contains("thumb, subtitles ×2"), "an episode's own files belong on its line")
        if ProcessInfo.processInfo.environment["HT_PRINT_REPORT"] != nil { print(text) }
    }
}
