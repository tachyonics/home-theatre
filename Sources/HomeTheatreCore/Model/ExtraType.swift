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
    /// Derived from ``ExtrasFolder/all`` so there is one list, not two.
    public static let folderNames: [String: ExtraType] = Dictionary(
        uniqueKeysWithValues: ExtrasFolder.all.map { ($0.name, $0.type) }
    )

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


/// A recognised extras sub-folder.
///
/// This, not ``ExtraType``, is the unit an extra is filed under: `extras` and
/// `specials` both resolve to ``ExtraType/unknown``, so a list keyed by type would
/// merge two destinations that are distinct on disk. Placing an extra means moving
/// a file into one of these folders, so the folder is the identity that matters.
///
/// Folders sit directly under the item's own folder — nested folders are not
/// supported — and the order here is the order Emby documents them in.
public struct ExtrasFolder: Sendable, Hashable, Identifiable {
    public var name: String
    public var type: ExtraType

    public var id: String { name }

    public init(name: String, type: ExtraType) {
        self.name = name
        self.type = type
    }

    public static let all: [ExtrasFolder] = [
        ExtrasFolder(name: "extras", type: .unknown),
        ExtrasFolder(name: "specials", type: .unknown),
        ExtrasFolder(name: "shorts", type: .short),
        ExtrasFolder(name: "scenes", type: .scene),
        ExtrasFolder(name: "featurettes", type: .featurette),
        ExtrasFolder(name: "behind the scenes", type: .behindTheScenes),
        ExtrasFolder(name: "deleted scenes", type: .deletedScene),
        ExtrasFolder(name: "interviews", type: .interview),
        ExtrasFolder(name: "trailers", type: .trailer),
    ]

    public static func named(_ name: String) -> ExtrasFolder? {
        let lowered = name.lowercased().trimmingCharacters(in: .whitespaces)
        return all.first { $0.name == lowered }
    }

    /// Title case for display, leaving the on-disk name untouched.
    public var displayName: String {
        name.split(separator: " ").map(\.capitalized).joined(separator: " ")
    }
}
