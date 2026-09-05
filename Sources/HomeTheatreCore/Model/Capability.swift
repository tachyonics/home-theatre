import Foundation

/// Which level of the hierarchy an item sits at.
///
/// The capability list differs by level — an episode can carry subtitles and a
/// series cannot — and ``Capability/details`` needs the level to name itself.
public enum ItemLevel: String, Sendable, Hashable, Codable, CaseIterable {
    case series
    case season
    case episode

    public var displayName: String {
        switch self {
        case .series: "Series"
        case .season: "Season"
        case .episode: "Episode"
        }
    }
}

/// What a file *adds* to an item, rather than what the file is.
///
/// Emby recognises a sprawl of filenames for the same job — `folder.jpg`,
/// `poster.jpg`, `cover.jpg` and `default.jpg` are four ways to say "poster" — and
/// which one happens to be on disk matters far less than whether the item has a
/// poster at all. So this, not the file, is the unit the editor works in: a
/// capability is present or missing, and the files under it are the evidence.
///
/// The order of the cases is the order they are presented in.
public enum Capability: String, Sendable, Hashable, CaseIterable {
    /// The NFO sidecar, named for the level it describes — which is what Emby
    /// calls it too: `tvshow.nfo` carries series details, `season.nfo` season
    /// details, and an episode's sidecar is rooted at `<episodedetails>`.
    case details
    case poster
    case backdrop
    case banner
    case thumb
    case logo
    case clearArt
    case disc
    case themeSong
    case themeVideo
    case subtitles

    /// ``details`` reads as "Series Details" / "Season Details" / "Episode
    /// Details"; everything else names itself the same way at every level.
    public func displayName(at level: ItemLevel) -> String {
        switch self {
        case .details: "\(level.displayName) Details"
        case .poster: "Poster"
        case .backdrop: "Backdrop"
        case .banner: "Banner"
        case .thumb: "Thumb"
        case .logo: "Logo"
        case .clearArt: "Clear Art"
        case .disc: "Disc Art"
        case .themeSong: "Theme Song"
        case .themeVideo: "Theme Video"
        case .subtitles: "Subtitles"
        }
    }

    /// What Emby calls the corresponding image type, which is the name that shows
    /// up in its own metadata manager and API. `nil` for the capabilities that are
    /// not images.
    public var embyImageType: String? {
        switch self {
        case .poster: "Primary"
        case .backdrop: "Backdrop"
        case .banner: "Banner"
        case .thumb: "Thumb"
        case .logo: "Logo"
        case .clearArt: "Art"
        case .disc: "Disc"
        case .details, .themeSong, .themeVideo, .subtitles: nil
        }
    }

    /// One line on what having this actually buys, since the point of grouping by
    /// capability is that the answer is not obvious from a filename.
    public var purpose: String {
        switch self {
        case .details:
            "Titles, identity numbering, display ordering and lock state — everything Emby reads from the sidecar."
        case .poster:
            "The artwork shown wherever the item appears in a list."
        case .backdrop:
            "Full-bleed art behind the item's page. Any number can be supplied."
        case .banner:
            "Wide title card, for the layouts that show one."
        case .thumb:
            "Landscape still, used by episode lists and thumbnail views."
        case .logo:
            "Transparent title treatment, overlaid on the backdrop."
        case .clearArt:
            "Transparent character art, used by a few layouts."
        case .disc:
            "Disc-shaped art standing in for a physical release."
        case .themeSong:
            "Audio played in the background while browsing the item."
        case .themeVideo:
            "Video played in the background while browsing the item."
        case .subtitles:
            "External subtitle tracks, offered alongside the ones muxed into the file."
        }
    }

    /// Whether Emby uses every file it finds, or picks one and ignores the rest.
    ///
    /// For the single-valued ones the documented filenames are a *precedence list*
    /// — the first that exists wins — so a folder holding both `folder.jpg` and
    /// `poster.jpg` is showing only one of them, and the other is dead weight
    /// worth pointing at.
    public var isMultiValued: Bool {
        switch self {
        case .backdrop, .themeSong, .themeVideo, .subtitles: true
        case .details, .poster, .banner, .thumb, .logo, .clearArt, .disc: false
        }
    }

    public func applies(to level: ItemLevel) -> Bool {
        switch level {
        case .series, .season:
            // Emby's image table covers series and season folders alike; only
            // particular *filenames* within it are series-folder-only, and those
            // name a season rather than the series. Theme media is documented as
            // working in "any folder".
            self != .subtitles
        case .episode:
            // An episode is a file, not a folder: it gets a thumb, its
            // subtitles and its sidecar.
            [.details, .thumb, .subtitles].contains(self)
        }
    }

    public static func applicable(to level: ItemLevel) -> [Capability] {
        allCases.filter { $0.applies(to: level) }
    }
}

/// How an external subtitle file describes itself, read from the dot-separated
/// tokens between the media file's name and the extension.
public struct SubtitleDetail: Sendable, Hashable {
    /// The language token exactly as written — `spa`, `spanish`, `zh-CN`, or
    /// something like `English(Commentary)` when the name is being used to tell
    /// two tracks apart. `nil` when the file carries no token at all.
    public var language: String?
    public var isDefault: Bool
    public var isForced: Bool
    public var isHearingImpaired: Bool
    /// `srt`, `ass`, `vtt` — or `sub/idx` for the two-file pair, which is one
    /// track despite being two files on disk.
    public var format: String

    public init(
        language: String? = nil,
        isDefault: Bool = false,
        isForced: Bool = false,
        isHearingImpaired: Bool = false,
        format: String
    ) {
        self.language = language
        self.isDefault = isDefault
        self.isForced = isForced
        self.isHearingImpaired = isHearingImpaired
        self.format = format
    }

    /// `Spanish · forced · srt` — the flags in the order they are documented.
    public var summary: String {
        var parts: [String] = [language ?? "no language tag"]
        if isDefault { parts.append("default") }
        if isForced { parts.append("forced") }
        if isHearingImpaired { parts.append("SDH") }
        parts.append(format)
        return parts.joined(separator: " · ")
    }
}

/// One file backing one capability.
///
/// The file is kept alongside *why* it was claimed, because the naming rules are
/// numerous and easy to get subtly wrong — a `fanart-2.jpg` that turned out to be
/// read as a backdrop, or a `poster.jpg` that is being ignored because `folder.jpg`
/// sits beside it, are both things you can only see if the rule is recorded.
public struct MediaAsset: Sendable, Hashable {
    public var file: URL
    public var capability: Capability
    /// The documented naming rule that claimed this file, written the way Emby's
    /// table writes it: `folder.ext`, `backdropX.ext`, `season-specials-poster.ext`.
    public var rule: String
    /// Set when a higher-precedence filename for the same single-valued capability
    /// exists in the same place. The file is on disk and Emby never looks at it.
    public var isShadowed: Bool
    /// Where the file sits when that is not the item's own folder — a season image
    /// filed up in the series folder, or an episode thumb in `metadata/`.
    public var locationNote: String?
    public var subtitle: SubtitleDetail?
    public var byteCount: Int?

    public init(
        file: URL,
        capability: Capability,
        rule: String,
        isShadowed: Bool = false,
        locationNote: String? = nil,
        subtitle: SubtitleDetail? = nil,
        byteCount: Int? = nil
    ) {
        self.file = file
        self.capability = capability
        self.rule = rule
        self.isShadowed = isShadowed
        self.locationNote = locationNote
        self.subtitle = subtitle
        self.byteCount = byteCount
    }

    public var name: String { file.lastPathComponent }
}
