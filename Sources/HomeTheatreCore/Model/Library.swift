import Foundation

/// How Emby orders a series' episodes, from the series-level `<displayorder>` tag.
public enum SeriesDisplayOrder: String, Sendable, Hashable, CaseIterable {
    case aired
    case dvd
    case absolute

    /// Emby writes this value lower-cased and parses it case-insensitively.
    public init?(nfoValue: String) {
        self.init(rawValue: nfoValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }
}

/// Whether an episode's position in the display sequence was authored explicitly
/// or falls out of its identity numbering.
///
/// This is the distinction the editor surfaces: `pinned` items carry
/// `<displayseason>`/`<displayepisode>` on disk, `inherited` ones do not.
public enum DisplaySource: Sendable, Hashable {
    case inherited
    case pinned
}

public struct Extra: Sendable, Hashable {
    public var file: URL
    public var type: ExtraType
    public var parent: ExtraParent
    /// Extras get no NFO of their own — Emby derives the on-screen title from the
    /// filename, so this is the display title.
    public var title: String
    /// The recognised extras folder this sits in, or `nil` when it was bound by a
    /// filename suffix instead and therefore lives in no extras folder at all.
    public var folderName: String?

    public init(file: URL, type: ExtraType, parent: ExtraParent, title: String, folderName: String? = nil) {
        self.file = file
        self.type = type
        self.parent = parent
        self.title = title
        self.folderName = folderName
    }
}

public struct Episode: Sendable, Hashable {
    public var file: URL
    public var nfoURL: URL?

    // Identity — canonical, drives provider matching.
    public var season: Int?
    public var number: Int?
    /// `<episodenumberend>`, set for a multi-part story held in one file.
    public var numberEnd: Int?

    // Presentation — what the display sequence is built from.
    public var displaySeason: Int?
    public var displayNumber: Int?

    public var title: String?
    public var locked: Bool
    public var providerIds: [String: String]
    public var extras: [Extra]
    /// The thumb and external subtitles sitting beside the file.
    public var assets: [MediaAsset]

    public init(
        file: URL,
        nfoURL: URL? = nil,
        season: Int? = nil,
        number: Int? = nil,
        numberEnd: Int? = nil,
        displaySeason: Int? = nil,
        displayNumber: Int? = nil,
        title: String? = nil,
        locked: Bool = false,
        providerIds: [String: String] = [:],
        extras: [Extra] = [],
        assets: [MediaAsset] = []
    ) {
        self.file = file
        self.nfoURL = nfoURL
        self.season = season
        self.number = number
        self.numberEnd = numberEnd
        self.displaySeason = displaySeason
        self.displayNumber = displayNumber
        self.title = title
        self.locked = locked
        self.providerIds = providerIds
        self.extras = extras
        self.assets = assets
    }

    public var displaySource: DisplaySource {
        (displaySeason != nil || displayNumber != nil) ? .pinned : .inherited
    }

    public var isSpecial: Bool { (season ?? 0) == 0 }

    /// `S01E02`, or `S05E12-E13` for a merged multi-part file.
    public var identityLabel: String {
        guard let season, let number else { return "S??E??" }
        let base = String(format: "S%02dE%02d", season, number)
        if let end = numberEnd, end != number {
            return base + String(format: "-E%02d", end)
        }
        return base
    }
}

public struct Season: Sendable, Hashable {
    /// The effective season number. `season.nfo`'s `<seasonnumber>` wins over the
    /// folder name when the two disagree — Emby reads it into the season's index.
    public var number: Int
    /// What the folder name alone implied, retained so a disagreement can be shown
    /// rather than silently resolved.
    public var folderNumber: Int?
    public var folder: URL
    public var nfoURL: URL?
    public var title: String?
    public var locked: Bool
    public var providerIds: [String: String]
    public var episodes: [Episode]
    public var extras: [Extra]
    /// Images and theme media, whether they sit in this season's own folder or
    /// were filed up in the series folder as `seasonXX-poster.jpg`.
    public var assets: [MediaAsset]

    public init(
        number: Int,
        folderNumber: Int? = nil,
        folder: URL,
        nfoURL: URL? = nil,
        title: String? = nil,
        locked: Bool = false,
        providerIds: [String: String] = [:],
        episodes: [Episode] = [],
        extras: [Extra] = [],
        assets: [MediaAsset] = []
    ) {
        self.number = number
        self.folderNumber = folderNumber
        self.folder = folder
        self.nfoURL = nfoURL
        self.title = title
        self.locked = locked
        self.providerIds = providerIds
        self.episodes = episodes
        self.extras = extras
        self.assets = assets
    }

    public var isSpecials: Bool { number == 0 }

    /// True when `<seasonnumber>` relocated this season away from its folder name.
    public var numberOverriddenByNFO: Bool {
        guard let folderNumber else { return false }
        return folderNumber != number
    }
}

public struct Series: Sendable, Hashable {
    public var name: String
    public var folder: URL
    public var nfoURL: URL?
    public var displayOrder: SeriesDisplayOrder?
    public var providerIds: [String: String]
    public var seasons: [Season]
    public var extras: [Extra]
    /// Images and theme media in the series folder.
    public var assets: [MediaAsset]
    /// Video files under the series that could not be placed — the editor's
    /// "unassigned bin", and the raw material for extras assignment.
    public var unassigned: [URL]

    public init(
        name: String,
        folder: URL,
        nfoURL: URL? = nil,
        displayOrder: SeriesDisplayOrder? = nil,
        providerIds: [String: String] = [:],
        seasons: [Season] = [],
        extras: [Extra] = [],
        assets: [MediaAsset] = [],
        unassigned: [URL] = []
    ) {
        self.name = name
        self.folder = folder
        self.nfoURL = nfoURL
        self.displayOrder = displayOrder
        self.providerIds = providerIds
        self.seasons = seasons
        self.extras = extras
        self.assets = assets
        self.unassigned = unassigned
    }

    public var allEpisodes: [Episode] { seasons.flatMap(\.episodes) }
}

/// What the chosen folder turned out to be.
///
/// Pointing the tool at one series rather than the library root is an easy
/// mistake to make and produces nonsense if assumed away — every `Season NN`
/// folder comes back as a series. The scanner detects the shape instead.
public enum ScanMode: Sendable, Hashable {
    /// One directory per series.
    case library
    /// The folder is itself a single series.
    case singleSeries

    public var description: String {
        switch self {
        case .library: "library root"
        case .singleSeries: "single series folder"
        }
    }
}

public struct LibraryScanResult: Sendable {
    public var root: URL
    public var mode: ScanMode
    public var series: [Series]
    public var warnings: [String]

    public init(root: URL, mode: ScanMode = .library, series: [Series], warnings: [String] = []) {
        self.root = root
        self.mode = mode
        self.series = series
        self.warnings = warnings
    }
}
