import Foundation

/// Mirrors Emby/Jellyfin's `ExtraType` enum. Extras carry one of these; it is
/// derived at scan time from the containing folder name or a filename suffix,
/// never from metadata — there is no field for it in Emby's metadata editor.
public enum ExtraType: String, Sendable, Hashable, CaseIterable {
    case unknown
    case clip
    case trailer
    case behindTheScenes
    case deletedScene
    case interview
    case scene
    case sample
    case themeSong
    case themeVideo
    case featurette
    case short

    /// The extras sub-folder names Emby recognises, mapped to the type they imply.
    /// Folders must sit directly under the item's folder — nested folders are not supported.
    public static let folderNames: [String: ExtraType] = [
        "extras": .unknown,
        "specials": .unknown,
        "shorts": .short,
        "scenes": .scene,
        "featurettes": .featurette,
        "behind the scenes": .behindTheScenes,
        "deleted scenes": .deletedScene,
        "interviews": .interview,
        "trailers": .trailer,
    ]

    /// Filename suffixes that bind an extra to the sibling media file sharing its stem.
    /// Longest-match-first matters: `-deletedscene` must be tested before `-deleted`.
    public static let filenameSuffixes: [(suffix: String, type: ExtraType)] = [
        ("-behindthescenes", .behindTheScenes),
        ("-deletedscene", .deletedScene),
        ("-deleted", .deletedScene),
        ("-featurette", .featurette),
        ("-interview", .interview),
        ("-themevideo", .themeVideo),
        ("-themesong", .themeSong),
        ("-trailer", .trailer),
        ("-sample", .sample),
        ("-scene", .scene),
        ("-short", .short),
        ("-clip", .clip),
        ("-other", .unknown),
    ]

    public var displayName: String {
        switch self {
        case .unknown: "Extra"
        case .clip: "Clip"
        case .trailer: "Trailer"
        case .behindTheScenes: "Behind the Scenes"
        case .deletedScene: "Deleted Scene"
        case .interview: "Interview"
        case .scene: "Scene"
        case .sample: "Sample"
        case .themeSong: "Theme Song"
        case .themeVideo: "Theme Video"
        case .featurette: "Featurette"
        case .short: "Short"
        }
    }
}

/// Which level of the hierarchy an extra hangs off.
public enum ExtraParent: Sendable, Hashable {
    case series
    case season(Int)
    case episode(season: Int, number: Int)
}
