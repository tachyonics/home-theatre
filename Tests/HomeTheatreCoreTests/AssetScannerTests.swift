import Foundation
import XCTest
@testable import HomeTheatreCore

final class AssetScannerTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ht-assets-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func touch(_ path: String) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: url)
        return url
    }

    private func folderAssets(_ level: ItemLevel = .series, in folder: URL? = nil) -> FolderAssets {
        AssetScanner.folderAssets(level: level, listing: FolderListing.read(folder ?? root))
    }

    private func assets(for capability: Capability, in assets: [MediaAsset]) -> [MediaAsset] {
        assets.filter { $0.capability == capability }
    }

    // MARK: - Images

    /// The documented filenames for a single image are a precedence list, so the
    /// second one on disk is a file Emby never opens.
    func testPosterNamesShadowInDocumentedOrder() throws {
        try touch("poster.jpg")
        try touch("folder.jpg")
        try touch("cover.png")

        let posters = assets(for: .poster, in: folderAssets().own)
        XCTAssertEqual(posters.map(\.name), ["folder.jpg", "poster.jpg", "cover.png"])
        XCTAssertEqual(posters.map(\.isShadowed), [false, true, true])
        XCTAssertEqual(posters.first?.rule, "folder.ext")
    }

    func testBackdropsAccumulateAcrossEveryForm() throws {
        try touch("backdrop.jpg")
        try touch("backdrop2.jpg")
        try touch("fanart.jpg")
        try touch("background-3.jpg")
        try touch("art-1.jpg")
        try touch("extrafanart/fanart1.jpg")

        let backdrops = assets(for: .backdrop, in: folderAssets().own)
        XCTAssertEqual(backdrops.count, 6)
        XCTAssertTrue(backdrops.allSatisfy { !$0.isShadowed }, "backdrops are multi-valued, so none is ignored")
        XCTAssertEqual(
            backdrops.map(\.rule),
            ["backdrop.ext", "backdropX.ext", "fanart.ext", "backgroundX.ext", "artX.ext", "extrafanart/fanartX.ext"]
        )
    }

    /// `art.jpg` is a backdrop and `clearart.jpg` is not — one character apart,
    /// two different capabilities.
    func testArtAndClearArtAreDifferentCapabilities() throws {
        try touch("art.jpg")
        try touch("clearart.png")

        let own = folderAssets().own
        XCTAssertEqual(assets(for: .backdrop, in: own).map(\.name), ["art.jpg"])
        XCTAssertEqual(assets(for: .clearArt, in: own).map(\.name), ["clearart.png"])
    }

    func testShowImageOnlyCountsInTheSeriesFolder() throws {
        try touch("show.jpg")

        XCTAssertEqual(assets(for: .poster, in: folderAssets(.series).own).count, 1)
        XCTAssertTrue(folderAssets(.season).own.isEmpty, "show.ext names the series and means nothing in a season")
    }

    func testThumbAndLogoAlternatives() throws {
        try touch("landscape.jpg")
        try touch("logo.png")
        try touch("clearlogo.png")
        try touch("cdart.png")

        let own = folderAssets().own
        XCTAssertEqual(assets(for: .thumb, in: own).map(\.name), ["landscape.jpg"])
        XCTAssertEqual(assets(for: .logo, in: own).map(\.name), ["clearlogo.png", "logo.png"])
        XCTAssertEqual(assets(for: .logo, in: own).map(\.isShadowed), [false, true])
        XCTAssertEqual(assets(for: .disc, in: own).map(\.name), ["cdart.png"])
    }

    // MARK: - Season images kept in the series folder

    func testSeasonImagesInTheSeriesFolderAreScopedToTheirSeason() throws {
        try touch("season01-poster.jpg")
        try touch("season01-fanart.jpg")
        try touch("season-specials-banner.jpg")

        let scoped = folderAssets().seasonScoped
        XCTAssertEqual(scoped.map(\.season), [0, 1, 1])
        XCTAssertEqual(
            Set(scoped.map { "\($0.season):\($0.asset.capability.rawValue)" }),
            ["0:banner", "1:poster", "1:backdrop"]
        )
        XCTAssertTrue(scoped.allSatisfy { $0.asset.locationNote == "in the series folder" })
        XCTAssertTrue(folderAssets().own.isEmpty, "none of these describe the series itself")
    }

    /// Two seasons' images sitting side by side must not shadow each other.
    func testSeasonScopedImagesShadowPerSeason() throws {
        try touch("season01-poster.jpg")
        try touch("season02-poster.jpg")

        XCTAssertTrue(folderAssets().seasonScoped.allSatisfy { !$0.asset.isShadowed })
    }

    // MARK: - Theme media

    func testThemeSongAndThemeVideo() throws {
        try touch("theme.mp3")
        try touch("theme-music/opening.flac")
        try touch("backdrops/loop.mkv")

        let own = folderAssets().own
        XCTAssertEqual(assets(for: .themeSong, in: own).map(\.name), ["theme.mp3", "opening.flac"])
        XCTAssertEqual(assets(for: .themeVideo, in: own).map(\.name), ["loop.mkv"])
        XCTAssertEqual(assets(for: .themeVideo, in: own).first?.locationNote, "in backdrops/")
    }

    // MARK: - Episode-bound assets

    private func fileAssets(_ media: URL) -> [MediaAsset] {
        AssetScanner.fileAssets(for: media, listing: FolderListing.read(media.deletingLastPathComponent()))
    }

    func testEpisodeThumbPrefersTheSiblingOverTheMetadataFolder() throws {
        let episode = try touch("Show S01E01.mkv")
        try touch("Show S01E01-thumb.jpg")
        try touch("metadata/Show S01E01.jpg")

        let thumbs = assets(for: .thumb, in: fileAssets(episode))
        XCTAssertEqual(thumbs.map(\.rule), ["{name}-thumb.ext", "metadata/{name}.ext"])
        XCTAssertEqual(thumbs.map(\.isShadowed), [false, true])
    }

    func testSubtitleTokensAreRead() throws {
        let episode = try touch("Show S01E01.mkv")
        try touch("Show S01E01.srt")
        try touch("Show S01E01.spa.forced.srt")
        try touch("Show S01E01.eng.sdh.default.ass")

        let subtitles = assets(for: .subtitles, in: fileAssets(episode))
        XCTAssertEqual(subtitles.count, 3)

        let plain = try XCTUnwrap(subtitles.first { $0.name == "Show S01E01.srt" }).subtitle
        XCTAssertNil(plain?.language)
        XCTAssertEqual(plain?.format, "srt")

        let spanish = try XCTUnwrap(subtitles.first { $0.name.contains(".spa.") }).subtitle
        XCTAssertEqual(spanish?.language, "spa")
        XCTAssertTrue(spanish?.isForced == true)
        XCTAssertFalse(spanish?.isDefault == true)

        let english = try XCTUnwrap(subtitles.first { $0.name.contains(".eng.") }).subtitle
        XCTAssertEqual(english?.language, "eng")
        XCTAssertTrue(english?.isDefault == true)
        XCTAssertTrue(english?.isHearingImpaired == true)
        XCTAssertEqual(english?.format, "ass")
    }

    /// `.foreign` is the second spelling of forced, and a `.sub`/`.idx` pair is one
    /// track split across two files.
    func testForeignIsForcedAndSubIdxIsOneTrack() throws {
        let episode = try touch("Show S01E02.mkv")
        try touch("Show S01E02.fre.foreign.vtt")
        try touch("Show S01E02.ger.sub")
        try touch("Show S01E02.ger.idx")

        let subtitles = assets(for: .subtitles, in: fileAssets(episode))
        XCTAssertEqual(subtitles.count, 2)
        XCTAssertTrue(try XCTUnwrap(subtitles.first { $0.name.contains("fre") }).subtitle?.isForced == true)

        let german = try XCTUnwrap(subtitles.first { $0.name.contains("ger") })
        XCTAssertEqual(german.subtitle?.format, "sub/idx")
        XCTAssertEqual(german.rule, "{name}.ger.sub/idx")
    }

    /// The separating dot is what stops an extra's subtitle being read as the
    /// episode's.
    func testAnExtrasSubtitleIsNotClaimedByTheEpisode() throws {
        let episode = try touch("Show S01E03.mkv")
        try touch("Show S01E03-behindthescenes.mkv")
        try touch("Show S01E03-behindthescenes.srt")

        XCTAssertTrue(assets(for: .subtitles, in: fileAssets(episode)).isEmpty)
    }

    // MARK: - Inventory

    func testInventoryListsMissingCapabilitiesToo() throws {
        try touch("folder.jpg")
        let entries = CapabilityInventory.entries(
            level: .series,
            nfoURL: nil,
            assets: folderAssets().own
        )

        XCTAssertEqual(entries.count, Capability.applicable(to: .series).count)
        XCTAssertFalse(entries.contains { $0.capability == .subtitles }, "a series folder carries no subtitles")

        let poster = try XCTUnwrap(entries.first { $0.capability == .poster })
        XCTAssertTrue(poster.isPresent)
        XCTAssertEqual(poster.countLabel, "1 file")

        let banner = try XCTUnwrap(entries.first { $0.capability == .banner })
        XCTAssertFalse(banner.isPresent)
        XCTAssertEqual(banner.countLabel, "missing")

        let details = try XCTUnwrap(entries.first { $0.capability == .details })
        XCTAssertEqual(details.displayName, "Series Details")
        XCTAssertEqual(details.countLabel, "missing")
    }

    func testEpisodeInventoryIsNarrower() {
        XCTAssertEqual(
            Capability.applicable(to: .episode),
            [.details, .thumb, .subtitles]
        )
    }
}
