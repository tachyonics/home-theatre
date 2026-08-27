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

    public init(file: URL, type: ExtraType, parent: ExtraParent, title: String) {
        self.file = file
        self.type = type
        self.parent = parent
        self.title = title
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
        extras: [Extra] = []
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
    public var number: Int
    public var folder: URL
    public var nfoURL: URL?
    public var episodes: [Episode]
    public var extras: [Extra]

    public init(number: Int, folder: URL, nfoURL: URL? = nil, episodes: [Episode] = [], extras: [Extra] = []) {
        self.number = number
        self.folder = folder
        self.nfoURL = nfoURL
        self.episodes = episodes
        self.extras = extras
    }

    public var isSpecials: Bool { number == 0 }
}

public struct Series: Sendable, Hashable {
    public var name: String
    public var folder: URL
    public var nfoURL: URL?
    public var displayOrder: SeriesDisplayOrder?
    public var providerIds: [String: String]
    public var seasons: [Season]
    public var extras: [Extra]
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
        unassigned: [URL] = []
    ) {
        self.name = name
        self.folder = folder
        self.nfoURL = nfoURL
        self.displayOrder = displayOrder
        self.providerIds = providerIds
        self.seasons = seasons
        self.extras = extras
        self.unassigned = unassigned
    }

    public var allEpisodes: [Episode] { seasons.flatMap(\.episodes) }
}

public struct LibraryScanResult: Sendable {
    public var root: URL
    public var series: [Series]
    public var warnings: [String]

    public init(root: URL, series: [Series], warnings: [String] = []) {
        self.root = root
        self.series = series
        self.warnings = warnings
    }
}
