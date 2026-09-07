import XCTest
@testable import HomeTheatreCore

/// The pending-change machinery: identity, what a filing produces, and what the
/// executor will and will not do to the disk.
final class ChangeTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        let created = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("change-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: created, withIntermediateDirectories: true)

        // Canonical, because the temporary directory is reached through a symlink:
        // `/var` → `/private/var`. Enumerating a folder reports the real path, so a
        // URL built from an uncanonical root would differ from the one a scan
        // produced for the same file by that prefix alone.
        root = (try? created.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath)
            .map { URL(fileURLWithPath: $0) } ?? created
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func touch(_ relative: String, bytes: String = "x") throws -> URL {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try bytes.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - Identity

    func testEntityIdsAreDistinctPerEntity() {
        let one = Episode(file: root.appendingPathComponent("a.mkv"))
        let two = Episode(file: root.appendingPathComponent("b.mkv"))
        XCTAssertNotEqual(one.id, two.id)
    }

    func testIdSurvivesTheInPlaceMutationTheScannerDoes() {
        var season = Season(number: 1, folder: root)
        let original = season.id

        // Exactly what LibraryScanner does after building a season: fills it in.
        season.episodes = [Episode(file: root.appendingPathComponent("a.mkv"))]
        season.assets = []
        season.title = "Series 1"

        XCTAssertEqual(season.id, original, "filling an entity in must not re-identify it")
    }

    func testAnEpisodeIsFoundByItsId() throws {
        let episode = Episode(file: root.appendingPathComponent("Season 1/Show S01E03.mkv"), season: 1, number: 3)
        let season = Season(number: 1, folder: root.appendingPathComponent("Season 1"), episodes: [episode])
        let series = Series(name: "Show", folder: root, seasons: [season])
        let result = LibraryScanResult(root: root, series: [series])

        let found = try XCTUnwrap(result.locate(episode: episode.id))
        XCTAssertEqual(found.episode.id, episode.id)
        XCTAssertEqual(found.season.number, 1, "the owning season is what a filing needs")
        XCTAssertEqual(found.series.name, "Show")

        XCTAssertNil(result.locate(episode: UUID()), "an unknown id resolves to nothing rather than the first episode")
    }

    func testLabelFallsBackToTheFilenameWithoutIdentityNumbering() {
        let numbered = Episode(file: root.appendingPathComponent("Show S01E03.mkv"), season: 1, number: 3)
        XCTAssertEqual(numbered.entityLabel, "S01E03")

        let unmatched = Episode(file: root.appendingPathComponent("Some Documentary.mkv"))
        XCTAssertEqual(unmatched.entityLabel, "Some Documentary.mkv")
    }

    // MARK: - Filing an episode as an extra

    func testFilingMovesTheVideoAndEverySidecar() throws {
        let seasonFolder = root.appendingPathComponent("Season 1")
        let episode = Episode(
            file: seasonFolder.appendingPathComponent("Show S01E03.mkv"),
            nfoURL: seasonFolder.appendingPathComponent("Show S01E03.nfo"),
            season: 1,
            number: 3,
            assets: [
                MediaAsset(
                    file: seasonFolder.appendingPathComponent("Show S01E03-thumb.jpg"),
                    capability: .thumb,
                    rule: "{name}-thumb.ext"
                ),
                MediaAsset(
                    file: seasonFolder.appendingPathComponent("Show S01E03.eng.srt"),
                    capability: .subtitles,
                    rule: "{name}.eng.srt"
                ),
            ]
        )
        let season = Season(number: 1, folder: seasonFolder, episodes: [episode])
        let folder = try XCTUnwrap(ExtrasFolder.named("featurettes"))

        let action = try XCTUnwrap(ExtrasFiling.action(episode: episode, in: season, folder: folder))

        XCTAssertEqual(
            action.title,
            "Set as Featurette extra",
            "the row names the decision, not the mechanism"
        )
        XCTAssertEqual(action.detail, "into Season 1/featurettes/")

        XCTAssertEqual(
            action.steps.map(\.sourceFile.lastPathComponent),
            ["Show S01E03.mkv", "Show S01E03.nfo", "Show S01E03-thumb.jpg", "Show S01E03.eng.srt"],
            "one action, whose steps are the video and everything bound to it by filename"
        )

        for step in action.steps {
            guard case .move(_, let to) = step else { return XCTFail("filing only moves") }
            XCTAssertEqual(to.deletingLastPathComponent().lastPathComponent, "featurettes")
            XCTAssertEqual(
                to.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent,
                "Season 1",
                "the extras folder belongs to the season holding the episode"
            )
        }
    }

    func testAFilingSaysWhatItWouldMakeTrue() throws {
        let seasonFolder = root.appendingPathComponent("Season 1")
        let episode = Episode(file: seasonFolder.appendingPathComponent("Show S01E03.mkv"), season: 1, number: 3)
        let season = Season(number: 1, folder: seasonFolder, episodes: [episode])
        let folder = try XCTUnwrap(ExtrasFolder.named("featurettes"))

        let action = try XCTUnwrap(ExtrasFiling.action(episode: episode, in: season, folder: folder))

        XCTAssertEqual(
            action.intent,
            .fileEpisodeAsExtra(folder: folder, owner: .season),
            "the browser must not have to read the decision back out of the file steps"
        )
    }

    // MARK: - Filing an episode as an extra of the series

    func testFilingUnderTheSeriesLandsInTheSeriesFolder() throws {
        let seriesFolder = root.appendingPathComponent("Show")
        let seasonFolder = seriesFolder.appendingPathComponent("Season 1")
        let episode = Episode(
            file: seasonFolder.appendingPathComponent("Show S01E03.mkv"),
            nfoURL: seasonFolder.appendingPathComponent("Show S01E03.nfo"),
            season: 1,
            number: 3
        )
        let season = Season(number: 1, folder: seasonFolder, episodes: [episode])
        let series = Series(name: "Show", folder: seriesFolder, seasons: [season])
        let folder = try XCTUnwrap(ExtrasFolder.named("behind the scenes"))

        let action = try XCTUnwrap(ExtrasFiling.action(episode: episode, in: series, folder: folder))

        XCTAssertEqual(action.title, "Set as Behind the Scenes extra")
        XCTAssertEqual(action.detail, "into Show/behind the scenes/")
        XCTAssertEqual(action.intent, .fileEpisodeAsExtra(folder: folder, owner: .series))

        XCTAssertEqual(
            action.steps.map(\.sourceFile.lastPathComponent),
            ["Show S01E03.mkv", "Show S01E03.nfo"],
            "the sidecars travel whichever level the extra is filed at"
        )
        for step in action.steps {
            guard case .move(_, let to) = step else { return XCTFail("filing only moves") }
            XCTAssertEqual(to.deletingLastPathComponent().lastPathComponent, "behind the scenes")
            XCTAssertEqual(
                to.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent,
                seriesFolder.lastPathComponent,
                "the extras folder belongs to the series, not to the season the episode left"
            )
        }
    }

    func testASeriesFilingProjectsOntoTheSeriesRatherThanTheSeason() throws {
        let seriesFolder = root.appendingPathComponent("Show")
        let seasonFolder = seriesFolder.appendingPathComponent("Season 1")
        let filed = Episode(file: seasonFolder.appendingPathComponent("Show S01E01.mkv"), season: 1, number: 1)
        let untouched = Episode(file: seasonFolder.appendingPathComponent("Show S01E02.mkv"), season: 1, number: 2)
        let season = Season(number: 1, folder: seasonFolder, episodes: [filed, untouched])
        let result = LibraryScanResult(
            root: root,
            series: [Series(name: "Show", folder: seriesFolder, seasons: [season])]
        )

        let folder = try XCTUnwrap(ExtrasFolder.named("interviews"))
        let located = try XCTUnwrap(result.locate(episode: filed.id))
        let action = try XCTUnwrap(ExtrasFiling.action(episode: located.episode, in: located.series, folder: folder))

        var set = ChangeSet()
        set.add(action, to: located.entityRef)

        let filing = try XCTUnwrap(set.pendingFilings(in: result).first)
        XCTAssertEqual(filing.owner, .series)
        XCTAssertEqual(filing.destination, seriesFolder.appendingPathComponent("interviews/Show S01E01.mkv"))
        XCTAssertEqual(filing.futureExtra.parent, .series, "an extra of the series hangs off the series")

        let projected = try XCTUnwrap(result.applyingPendingFilings([filing]).series.first)
        XCTAssertEqual(projected.extras.map(\.title), ["Show S01E01"])
        XCTAssertEqual(projected.extras.map(\.type), [.interview])
        XCTAssertEqual(
            projected.seasons.first?.episodes.map(\.number),
            [2],
            "the episode still leaves the season it was in"
        )
        XCTAssertTrue(
            projected.seasons.first?.extras.isEmpty ?? false,
            "and must not also be drawn as an extra of the season it left"
        )
    }

    /// The same round trip as the season case: what the browser drew before
    /// applying has to be what the rescan finds after, one level up.
    func testAnEpisodeFiledAsASeriesExtraRescansAsOne() throws {
        let series = root.appendingPathComponent("Doctor Who (2005)")
        try touch("Doctor Who (2005)/tvshow.nfo", bytes: "<tvshow><title>Doctor Who</title></tvshow>")
        try touch("Doctor Who (2005)/Season 1/Doctor Who S01E01.mkv")
        try touch("Doctor Who (2005)/Season 1/Doctor Who S01E01.nfo", bytes: "<episodedetails><season>1</season><episode>1</episode></episodedetails>")
        try touch("Doctor Who (2005)/Season 1/Doctor Who S01E02.mkv")

        let before = try LibraryScanner().scan(root: series)
        let episode = try XCTUnwrap(before.series.first?.seasons.first?.episodes.first { $0.number == 1 })
        let located = try XCTUnwrap(before.locate(episode: episode.id))

        let folder = try XCTUnwrap(ExtrasFolder.named("behind the scenes"))
        let action = try XCTUnwrap(ExtrasFiling.action(episode: located.episode, in: located.series, folder: folder))

        var set = ChangeSet()
        set.add(action, to: located.entityRef)
        let filings = set.pendingFilings(in: before)
        let projected = try XCTUnwrap(before.applyingPendingFilings(filings).series.first)

        guard case .success = ChangeExecutor.apply(action) else {
            return XCTFail("\(action.title) failed")
        }

        let after = try LibraryScanner().scan(root: series)
        let seriesAfter = try XCTUnwrap(after.series.first)

        XCTAssertEqual(seriesAfter.extras.map(\.type), [.behindTheScenes])
        XCTAssertEqual(seriesAfter.extras.first?.folderName, "behind the scenes")
        XCTAssertEqual(seriesAfter.seasons.first?.episodes.map(\.number), [2])
        XCTAssertTrue(seriesAfter.unassigned.isEmpty, "a filed extra is placed, not unassigned")

        XCTAssertEqual(
            projected.extras,
            seriesAfter.extras,
            "the preview shown before applying must be exactly what the rescan finds after"
        )
    }

    // MARK: - Revising a filing

    /// A queued episode has not moved yet, so a second filing has to describe the
    /// whole move from where the scan found it — not a move from the folder the
    /// first filing was going to put it in.
    func testFilingAgainReplacesTheFirstDecision() throws {
        let seriesFolder = root.appendingPathComponent("Show")
        let seasonFolder = seriesFolder.appendingPathComponent("Season 1")
        let episode = Episode(
            file: seasonFolder.appendingPathComponent("Show S01E03.mkv"),
            nfoURL: seasonFolder.appendingPathComponent("Show S01E03.nfo"),
            season: 1,
            number: 3
        )
        let season = Season(number: 1, folder: seasonFolder, episodes: [episode])
        let series = Series(name: "Show", folder: seriesFolder, seasons: [season])
        let result = LibraryScanResult(root: root, series: [series])
        let located = try XCTUnwrap(result.locate(episode: episode.id))

        let featurettes = try XCTUnwrap(ExtrasFolder.named("featurettes"))
        let interviews = try XCTUnwrap(ExtrasFolder.named("interviews"))

        var set = ChangeSet()
        set.file(try XCTUnwrap(ExtrasFiling.action(episode: episode, in: season, folder: featurettes)), for: located.entityRef)
        set.file(try XCTUnwrap(ExtrasFiling.action(episode: episode, in: season, folder: interviews)), for: located.entityRef)

        XCTAssertEqual(set.count, 1, "changing your mind is one queued change, not two")
        XCTAssertEqual(set.entities.count, 1)

        let filing = try XCTUnwrap(set.pendingFilings(in: result).first)
        XCTAssertEqual(filing.folder, interviews, "the second decision is the one that stands")
        XCTAssertEqual(
            filing.action.steps.map(\.sourceFile),
            [episode.file, try XCTUnwrap(episode.nfoURL)],
            "the steps still start from the scan, since nothing has been applied"
        )
    }

    /// The level can change too: filed as a season extra, then dragged up to the
    /// series, is still one change.
    func testRefilingAtAnotherLevelIsStillOneChange() throws {
        let seriesFolder = root.appendingPathComponent("Show")
        let seasonFolder = seriesFolder.appendingPathComponent("Season 1")
        let episode = Episode(file: seasonFolder.appendingPathComponent("Show S01E03.mkv"), season: 1, number: 3)
        let season = Season(number: 1, folder: seasonFolder, episodes: [episode])
        let series = Series(name: "Show", folder: seriesFolder, seasons: [season])
        let result = LibraryScanResult(root: root, series: [series])
        let located = try XCTUnwrap(result.locate(episode: episode.id))
        let folder = try XCTUnwrap(ExtrasFolder.named("interviews"))

        var set = ChangeSet()
        set.file(try XCTUnwrap(ExtrasFiling.action(episode: episode, in: season, folder: folder)), for: located.entityRef)
        set.file(try XCTUnwrap(ExtrasFiling.action(episode: episode, in: series, folder: folder)), for: located.entityRef)

        XCTAssertEqual(set.count, 1)
        let filing = try XCTUnwrap(set.pendingFilings(in: result).first)
        XCTAssertEqual(filing.owner, .series)
        XCTAssertEqual(filing.destination, seriesFolder.appendingPathComponent("interviews/Show S01E03.mkv"))
    }

    func testCancellingAFilingPutsTheEpisodeBack() throws {
        let seasonFolder = root.appendingPathComponent("Show/Season 1")
        let episode = Episode(file: seasonFolder.appendingPathComponent("Show S01E01.mkv"), season: 1, number: 1)
        let season = Season(number: 1, folder: seasonFolder, episodes: [episode])
        let result = LibraryScanResult(
            root: root,
            series: [Series(name: "Show", folder: root.appendingPathComponent("Show"), seasons: [season])]
        )
        let located = try XCTUnwrap(result.locate(episode: episode.id))
        let folder = try XCTUnwrap(ExtrasFolder.named("featurettes"))

        var set = ChangeSet()
        set.file(try XCTUnwrap(ExtrasFiling.action(episode: episode, in: season, folder: folder)), for: located.entityRef)

        XCTAssertEqual(set.removeFilings(forEntityID: episode.id).count, 1)
        XCTAssertTrue(set.isEmpty, "nothing was applied, so undoing the decision is the whole of the change")

        let projected = try XCTUnwrap(result.applyingPendingFilings(set.pendingFilings(in: result)).series.first)
        XCTAssertEqual(projected.seasons.first?.episodes.map(\.number), [1], "and the episode is an episode again")
        XCTAssertTrue(projected.seasons.first?.extras.isEmpty ?? false)

        XCTAssertTrue(
            set.removeFilings(forEntityID: episode.id).isEmpty,
            "an episode with nothing queued reports nothing removed, so a drop meaning nothing can be refused"
        )
    }

    func testSupersedingLeavesOtherChangesToTheSameEpisodeAlone() throws {
        let seasonFolder = root.appendingPathComponent("Season 1")
        let episode = Episode(file: seasonFolder.appendingPathComponent("Show S01E03.mkv"), season: 1, number: 3)
        let season = Season(number: 1, folder: seasonFolder, episodes: [episode])
        let entity = EntityRef(id: episode.id, level: .episode, label: "S01E03")
        let folder = try XCTUnwrap(ExtrasFolder.named("featurettes"))

        var set = ChangeSet()
        set.add(action("something else"), to: entity)
        set.file(try XCTUnwrap(ExtrasFiling.action(episode: episode, in: season, folder: folder)), for: entity)
        set.removeFilings(forEntityID: episode.id)

        XCTAssertEqual(
            set.actions(for: entity).map(\.title),
            ["something else"],
            "only the filing is a decision a later filing revises"
        )
    }

    // MARK: - Projecting the queue back onto the library

    func testAQueuedFilingProjectsOntoTheSeasonThatHoldsTheEpisode() throws {
        let seasonFolder = root.appendingPathComponent("Show/Season 2")
        let episode = Episode(file: seasonFolder.appendingPathComponent("Show S02E04.mkv"), season: 2, number: 4)
        let season = Season(number: 2, folder: seasonFolder, episodes: [episode])
        let series = Series(name: "Show", folder: root.appendingPathComponent("Show"), seasons: [season])
        let result = LibraryScanResult(root: root, series: [series])

        let folder = try XCTUnwrap(ExtrasFolder.named("interviews"))
        let located = try XCTUnwrap(result.locate(episode: episode.id))
        let action = try XCTUnwrap(ExtrasFiling.action(episode: located.episode, in: located.season, folder: folder))

        var set = ChangeSet()
        set.add(action, to: located.entityRef)

        let filings = set.pendingFilings(in: result)
        XCTAssertEqual(filings.count, 1)
        let filing = try XCTUnwrap(filings.first)

        XCTAssertEqual(filing.folder, folder)
        XCTAssertEqual(filing.season.number, 2, "the season holding the episode, not the one selected")
        XCTAssertEqual(filing.series.name, "Show")
        XCTAssertEqual(filing.destination, seasonFolder.appendingPathComponent("interviews/Show S02E04.mkv"))
        XCTAssertEqual(filing.id, action.id, "a projection and its queue row are one change")
    }

    func testAProjectedLibraryShowsTheEpisodeWhereItIsGoing() throws {
        let seasonFolder = root.appendingPathComponent("Show/Season 1")
        let filed = Episode(file: seasonFolder.appendingPathComponent("Show S01E01.mkv"), season: 1, number: 1)
        let untouched = Episode(file: seasonFolder.appendingPathComponent("Show S01E02.mkv"), season: 1, number: 2)
        let season = Season(number: 1, folder: seasonFolder, episodes: [filed, untouched])
        let series = Series(name: "Show", folder: root.appendingPathComponent("Show"), seasons: [season])
        let result = LibraryScanResult(root: root, series: [series])

        let folder = try XCTUnwrap(ExtrasFolder.named("featurettes"))
        let located = try XCTUnwrap(result.locate(episode: filed.id))
        let action = try XCTUnwrap(ExtrasFiling.action(episode: located.episode, in: located.season, folder: folder))

        var set = ChangeSet()
        set.add(action, to: located.entityRef)

        let projected = result.applyingPendingFilings(set.pendingFilings(in: result))
        let projectedSeason = try XCTUnwrap(projected.series.first?.seasons.first)

        XCTAssertEqual(
            projectedSeason.episodes.map(\.number),
            [2],
            "a filed episode stops being drawn where it no longer belongs"
        )
        XCTAssertEqual(projectedSeason.extras.map(\.folderName), ["featurettes"])
        XCTAssertEqual(projectedSeason.extras.map(\.title), ["Show S01E01"])
        XCTAssertEqual(projectedSeason.id, season.id, "projecting must not re-identify what it did not change")

        XCTAssertNil(
            projected.locate(episode: filed.id),
            "the projection describes a disk that does not exist yet, so it cannot be queued against"
        )
        XCTAssertNotNil(projected.locate(episode: untouched.id), "everything else stays findable")
    }

    func testProjectingNothingChangesNothing() throws {
        let season = Season(
            number: 1,
            folder: root.appendingPathComponent("Season 1"),
            episodes: [Episode(file: root.appendingPathComponent("Season 1/Show S01E01.mkv"), season: 1, number: 1)]
        )
        let result = LibraryScanResult(root: root, series: [Series(name: "Show", folder: root, seasons: [season])])

        let projected = result.applyingPendingFilings([])
        XCTAssertEqual(projected.series.first?.seasons.first?.episodes.count, 1)
        XCTAssertTrue(projected.series.first?.seasons.first?.extras.isEmpty ?? false)
    }

    func testActionsWithNothingToPreviewProjectToNothing() {
        let entity = EntityRef(id: UUID(), level: .episode, label: "S01E03")
        var set = ChangeSet()
        set.add(action("a"), to: entity)

        XCTAssertTrue(
            set.pendingFilings(in: LibraryScanResult(root: root, series: [])).isEmpty,
            "an action carrying no intent, and one naming an episode this scan does not have, both project to nothing"
        )
    }

    func testTwoFoldersSharingATypeAreDistinguishable() throws {
        let seasonFolder = root.appendingPathComponent("Season 1")
        let episode = Episode(file: seasonFolder.appendingPathComponent("Show S01E03.mkv"), season: 1, number: 3)
        let season = Season(number: 1, folder: seasonFolder, episodes: [episode])

        let extras = try XCTUnwrap(ExtrasFolder.named("extras"))
        let specials = try XCTUnwrap(ExtrasFolder.named("specials"))

        let one = try XCTUnwrap(ExtrasFiling.action(episode: episode, in: season, folder: extras))
        let two = try XCTUnwrap(ExtrasFiling.action(episode: episode, in: season, folder: specials))

        XCTAssertEqual(one.title, two.title, "both folders carry the same ExtraType")
        XCTAssertNotEqual(one.detail, two.detail, "so the folder has to be nameable separately")
    }

    func testFilingSkipsAFileAlreadyInTheDestination() throws {
        let seasonFolder = root.appendingPathComponent("Season 1")
        let episode = Episode(
            file: seasonFolder.appendingPathComponent("featurettes/Show S01E03.mkv"),
            season: 1,
            number: 3
        )
        let season = Season(number: 1, folder: seasonFolder, episodes: [episode])
        let folder = try XCTUnwrap(ExtrasFolder.named("featurettes"))

        XCTAssertNil(
            ExtrasFiling.action(episode: episode, in: season, folder: folder),
            "an action that would do nothing should not be queued at all"
        )
    }

    // MARK: - Executing

    func testApplyingCreatesTheExtrasFolderAndMovesTheFile() throws {
        let source = try touch("Season 1/Show S01E03.mkv")
        let target = root.appendingPathComponent("Season 1/featurettes/Show S01E03.mkv")

        let action = PendingAction(title: "", steps: [.move(from: source, to: target)])
        guard case .success = ChangeExecutor.apply(action) else {
            return XCTFail("a move into a folder that does not exist yet should create it")
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path), "a move leaves nothing behind")
    }

    func testApplyingRefusesRatherThanOverwrites() throws {
        let source = try touch("Season 1/Show S01E03.mkv", bytes: "new")
        let target = try touch("Season 1/featurettes/Show S01E03.mkv", bytes: "existing")

        let result = ChangeExecutor.apply(PendingAction(title: "", steps: [.move(from: source, to: target)]))

        guard case .failure(let error) = result else {
            return XCTFail("overwriting a file the review never mentioned is never right")
        }
        XCTAssertEqual(error, .destinationExists(target))
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "existing")
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path), "a refused move leaves the source alone")
    }

    func testApplyingReportsAVanishedSource() {
        let missing = root.appendingPathComponent("gone.mkv")
        let result = ChangeExecutor.apply(
            PendingAction(title: "", steps: [.move(from: missing, to: root.appendingPathComponent("x/gone.mkv"))])
        )
        guard case .failure(let error) = result else { return XCTFail("expected a failure") }
        XCTAssertEqual(error, .sourceMissing(missing))
    }

    func testAFailedStepUndoesTheOnesBeforeIt() throws {
        let video = try touch("Season 1/Show S01E03.mkv", bytes: "video")
        let subtitle = try touch("Season 1/Show S01E03.eng.srt", bytes: "subs")
        let destination = root.appendingPathComponent("Season 1/featurettes")

        // The subtitle already exists at the destination, so the second step must
        // fail — after the first has already moved the video.
        try touch("Season 1/featurettes/Show S01E03.eng.srt", bytes: "existing")

        let action = PendingAction(title: "Set as Featurette extra", steps: [
            .move(from: video, to: destination.appendingPathComponent("Show S01E03.mkv")),
            .move(from: subtitle, to: destination.appendingPathComponent("Show S01E03.eng.srt")),
        ])

        guard case .failure = ChangeExecutor.apply(action) else {
            return XCTFail("the second step cannot succeed")
        }

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: video.path),
            "the video must come back: an extra without its subtitles is the state grouping exists to prevent"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: destination.appendingPathComponent("Show S01E03.mkv").path),
            "and must not be left at the destination as well"
        )
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("Show S01E03.eng.srt"), encoding: .utf8), "existing")
    }

    // MARK: - The queue

    func testChangesGroupByEntityInQueueOrder() {
        let first = EntityRef(id: UUID(), level: .episode, label: "S01E03")
        let second = EntityRef(id: UUID(), level: .episode, label: "S01E04")

        var set = ChangeSet()
        set.add(action("a"), to: first)
        set.add(action("b"), to: first)
        set.add(action("c"), to: second)

        XCTAssertEqual(set.entities.map(\.label), ["S01E03", "S01E04"])
        XCTAssertEqual(set.count, 3)
        XCTAssertEqual(set.actions(for: first).map(\.title), ["a", "b"])
        XCTAssertEqual(set.allActions.map(\.action.title), ["a", "b", "c"])
    }

    func testAddingToAnEntityAgainDoesNotListItTwice() {
        let entity = EntityRef(id: UUID(), level: .episode, label: "S01E03")
        var set = ChangeSet()
        set.add(action("a"), to: entity)
        set.add(action("b"), to: entity)

        XCTAssertEqual(set.entities.count, 1)
        XCTAssertEqual(set.actions(for: entity).count, 2)
    }

    func testRemovingTheLastChangeRemovesTheEntity() {
        let entity = EntityRef(id: UUID(), level: .episode, label: "S01E03")
        var set = ChangeSet()
        let actions = [action("a"), action("b")]
        for queued in actions { set.add(queued, to: entity) }

        set.remove(actionID: actions[0].id)
        XCTAssertEqual(set.entities.count, 1, "an entity with changes left stays")

        set.remove(actionID: actions[1].id)
        XCTAssertTrue(set.isEmpty, "an entity heading with nothing under it is noise")
    }

    func testRemovingAnEntityDropsAllOfItsChanges() {
        let entity = EntityRef(id: UUID(), level: .episode, label: "S01E03")
        var set = ChangeSet()
        set.add(action("a"), to: entity)
        set.add(action("b"), to: entity)

        set.remove(entityID: entity.id)
        XCTAssertTrue(set.isEmpty)
        XCTAssertEqual(set.count, 0)
    }

    // MARK: - End to end

    /// The whole use case minus the drag: scan a real tree, file an episode as a
    /// featurette, apply, and rescan to confirm the library now reads that way.
    func testAnEpisodeFiledAsAFeaturetteRescansAsOne() throws {
        let series = root.appendingPathComponent("Doctor Who (2005)")
        try touch("Doctor Who (2005)/tvshow.nfo", bytes: "<tvshow><title>Doctor Who</title></tvshow>")
        try touch("Doctor Who (2005)/Season 1/Doctor Who S01E01.mkv")
        try touch("Doctor Who (2005)/Season 1/Doctor Who S01E01.nfo", bytes: "<episodedetails><season>1</season><episode>1</episode></episodedetails>")
        try touch("Doctor Who (2005)/Season 1/Doctor Who S01E01-thumb.jpg")
        try touch("Doctor Who (2005)/Season 1/Doctor Who S01E01.eng.srt")
        try touch("Doctor Who (2005)/Season 1/Doctor Who S01E02.mkv")

        let before = try LibraryScanner().scan(root: series)
        let seasonBefore = try XCTUnwrap(before.series.first?.seasons.first)
        XCTAssertEqual(seasonBefore.episodes.count, 2)

        let episode = try XCTUnwrap(seasonBefore.episodes.first { $0.number == 1 })
        let located = try XCTUnwrap(before.locate(episode: episode.id))
        XCTAssertEqual(located.entityRef.label, "Doctor Who (2005) — S01E01")

        let folder = try XCTUnwrap(ExtrasFolder.named("featurettes"))
        let action = try XCTUnwrap(ExtrasFiling.action(episode: located.episode, in: located.season, folder: folder))
        XCTAssertEqual(action.steps.count, 4, "one action: video, NFO, thumb and subtitle track")

        // What the browser draws while the change is still queued.
        var set = ChangeSet()
        set.add(action, to: located.entityRef)
        let filings = set.pendingFilings(in: before)
        let projected = try XCTUnwrap(filings.first)
        let projectedSeason = try XCTUnwrap(before.applyingPendingFilings(filings).series.first?.seasons.first)

        guard case .success = ChangeExecutor.apply(action) else {
            return XCTFail("\(action.title) failed")
        }

        // Nothing may be left behind referring to a file that has moved.
        let leftovers = try FileManager.default
            .contentsOfDirectory(atPath: series.appendingPathComponent("Season 1").path)
            .filter { $0.hasPrefix("Doctor Who S01E01") }
        XCTAssertTrue(leftovers.isEmpty, "sidecars must travel with the video, found \(leftovers)")

        let after = try LibraryScanner().scan(root: series)
        let seasonAfter = try XCTUnwrap(after.series.first?.seasons.first)

        XCTAssertEqual(seasonAfter.episodes.map(\.number), [2], "the filed episode is no longer an episode")
        XCTAssertEqual(seasonAfter.extras.map(\.type), [.featurette])
        XCTAssertEqual(seasonAfter.extras.first?.folderName, "featurettes")
        XCTAssertEqual(seasonAfter.extras.first?.title, "Doctor Who S01E01")
        XCTAssertTrue(after.series.first?.unassigned.isEmpty ?? false, "a filed extra is placed, not unassigned")

        XCTAssertEqual(
            projected.futureExtra,
            seasonAfter.extras.first,
            "the preview shown before applying must be exactly what the rescan finds after"
        )
        XCTAssertEqual(
            projectedSeason.episodes.map(\.number),
            seasonAfter.episodes.map(\.number),
            "and the season the preview drew must be the season that results"
        )
        XCTAssertEqual(projectedSeason.extras, seasonAfter.extras)
    }

    private func action(_ title: String) -> PendingAction {
        PendingAction(title: title, steps: [.trash(root.appendingPathComponent(title))])
    }
}
