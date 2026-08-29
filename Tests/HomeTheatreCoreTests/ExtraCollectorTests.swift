import Foundation
import XCTest
@testable import HomeTheatreCore

final class ExtraCollectorTests: XCTestCase {
    private func extra(_ name: String, _ type: ExtraType, parent: ExtraParent) -> Extra {
        Extra(file: URL(fileURLWithPath: "/tmp/\(name).mkv"), type: type, parent: parent, title: name)
    }

    private func sample() -> Series {
        let episode = Episode(
            file: URL(fileURLWithPath: "/tmp/S01E01.mkv"),
            season: 1,
            number: 1,
            extras: [extra("ep-bts", .behindTheScenes, parent: .episode(season: 1, number: 1))]
        )
        let season = Season(
            number: 1,
            folder: URL(fileURLWithPath: "/tmp/Season 1"),
            episodes: [episode],
            extras: [extra("season-featurette", .featurette, parent: .season(1))]
        )
        return Series(
            name: "Show",
            folder: URL(fileURLWithPath: "/tmp/Show"),
            seasons: [season],
            extras: [
                extra("series-doc", .behindTheScenes, parent: .series),
                extra("series-interview", .interview, parent: .series),
            ]
        )
    }

    func testEpisodeScopeIsDirectOnly() {
        let series = sample()
        let episode = series.seasons[0].episodes[0]
        let collected = ExtraCollector.collect(.episode(episode))

        XCTAssertEqual(collected.map(\.extra.title), ["ep-bts"])
        XCTAssertEqual(collected.first?.ownerLabel, "S01E01")
        XCTAssertTrue(collected.allSatisfy(\.isDirect))
    }

    func testSeasonScopeIncludesItsEpisodes() {
        let collected = ExtraCollector.collect(.season(sample().seasons[0]))

        XCTAssertEqual(collected.map(\.extra.title), ["season-featurette", "ep-bts"])
        XCTAssertEqual(collected.map(\.isDirect), [true, false])
        XCTAssertEqual(collected.last?.ownerLabel, "S01E01")
    }

    /// A series whose extras all hang off episodes must not present as empty.
    func testSeriesScopeReachesEveryLevel() {
        let collected = ExtraCollector.collect(.series(sample()))

        XCTAssertEqual(collected.count, 4)
        XCTAssertEqual(
            Set(collected.map(\.ownerLabel)),
            ["Series", "Season 1", "S01E01"]
        )
        XCTAssertEqual(collected.filter(\.isDirect).count, 2, "only the two series-level extras are direct")
    }

    func testSpecialsAreLabelledAsSuch() {
        let season = Season(
            number: 0,
            folder: URL(fileURLWithPath: "/tmp/Specials"),
            extras: [extra("x", .interview, parent: .season(0))]
        )
        XCTAssertEqual(ExtraCollector.collect(.season(season)).first?.ownerLabel, "Specials")
    }

    func testCountsByTypeAreOrderedByFrequency() {
        let collected = ExtraCollector.collect(.series(sample()))
        let counts = ExtraCollector.countsByType(collected)

        XCTAssertEqual(counts.first?.type, .behindTheScenes)
        XCTAssertEqual(counts.first?.count, 2)
        XCTAssertEqual(counts.map(\.count).reduce(0, +), collected.count)
        XCTAssertFalse(counts.contains { $0.type == .trailer }, "absent types are not offered")
    }
}

/// The folder list doubles as the set of drop destinations, so it is fixed rather
/// than derived from what happens to be present.
final class ExtrasFolderTests: XCTestCase {
    func testEveryDocumentedFolderIsOfferedInOrder() {
        XCTAssertEqual(
            ExtrasFolder.all.map(\.name),
            [
                "extras", "specials", "shorts", "scenes", "featurettes",
                "behind the scenes", "deleted scenes", "interviews", "trailers",
            ]
        )
    }

    /// `extras` and `specials` share a type, so a type-keyed list would merge two
    /// destinations that are distinct on disk.
    func testExtrasAndSpecialsShareATypeButStayDistinct() {
        let extras = try! XCTUnwrap(ExtrasFolder.named("extras"))
        let specials = try! XCTUnwrap(ExtrasFolder.named("specials"))

        XCTAssertEqual(extras.type, specials.type)
        XCTAssertNotEqual(extras, specials)
    }

    func testFolderNamesStayInSyncWithTheCanonicalList() {
        XCTAssertEqual(ExtraType.folderNames.count, ExtrasFolder.all.count)
        for folder in ExtrasFolder.all {
            XCTAssertEqual(ExtraType.folderNames[folder.name], folder.type, folder.name)
        }
    }

    func testNamedIsCaseAndWhitespaceInsensitive() {
        XCTAssertEqual(ExtrasFolder.named("Behind The Scenes")?.name, "behind the scenes")
        XCTAssertEqual(ExtrasFolder.named(" Trailers ")?.name, "trailers")
        XCTAssertNil(ExtrasFolder.named("Season 1"))
    }

    func testCountsCoverEmptyFoldersAndTheSuffixBucket() {
        let inFolder = Extra(
            file: URL(fileURLWithPath: "/tmp/interviews/a.mkv"),
            type: .interview,
            parent: .series,
            title: "a",
            folderName: "interviews"
        )
        let viaSuffix = Extra(
            file: URL(fileURLWithPath: "/tmp/Show S01E01-deleted.mkv"),
            type: .deletedScene,
            parent: .episode(season: 1, number: 1),
            title: "b"
        )
        let owned = [inFolder, viaSuffix].map { OwnedExtra(extra: $0, ownerLabel: "x", isDirect: true) }

        let counts = ExtraCollector.countsByFolder(owned)

        XCTAssertEqual(counts.folders.count, 9, "every folder is listed, populated or not")
        XCTAssertEqual(counts.folders.first { $0.folder.name == "interviews" }?.count, 1)
        XCTAssertEqual(counts.folders.first { $0.folder.name == "trailers" }?.count, 0)
        XCTAssertEqual(counts.suffixCount, 1)
        XCTAssertEqual(ExtraCollector.filing(of: viaSuffix), .filenameSuffix)
    }
}
