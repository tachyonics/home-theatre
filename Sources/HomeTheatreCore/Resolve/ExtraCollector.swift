import Foundation

/// An extra together with what owns it, so a list gathered across levels can say
/// where each one came from.
public struct OwnedExtra: Sendable, Hashable {
    public var extra: Extra
    /// `Series`, `Season 1`, `Specials`, `S01E01` — where the extra actually sits.
    public var ownerLabel: String
    /// False when the extra belongs to something beneath the item being asked about.
    public var isDirect: Bool

    public init(extra: Extra, ownerLabel: String, isDirect: Bool) {
        self.extra = extra
        self.ownerLabel = ownerLabel
        self.isDirect = isDirect
    }
}

public enum ExtraScope: Sendable {
    case series(Series)
    case season(Season)
    case episode(Episode)
}

/// Gathers the extras belonging to an item **and everything beneath it**.
///
/// Direct-only would be the stricter reading, but a series whose extras all hang
/// off episodes would then show an empty list, which is exactly when you most want
/// to see them. Each row is labelled with its real owner instead, so the nesting
/// stays legible.
///
/// Ownership is taken from where an extra is stored rather than from its `parent`,
/// because an extra whose filename named an episode that could not be matched stays
/// on the season while still carrying an `.episode` parent.
public enum ExtraCollector {
    public static func collect(_ scope: ExtraScope) -> [OwnedExtra] {
        switch scope {
        case .episode(let episode):
            return episode.extras.map {
                OwnedExtra(extra: $0, ownerLabel: episode.identityLabel, isDirect: true)
            }

        case .season(let season):
            let label = seasonLabel(season.number)
            var collected = season.extras.map {
                OwnedExtra(extra: $0, ownerLabel: label, isDirect: true)
            }
            for episode in season.episodes {
                collected += episode.extras.map {
                    OwnedExtra(extra: $0, ownerLabel: episode.identityLabel, isDirect: false)
                }
            }
            return collected

        case .series(let series):
            var collected = series.extras.map {
                OwnedExtra(extra: $0, ownerLabel: "Series", isDirect: true)
            }
            for season in series.seasons {
                let label = seasonLabel(season.number)
                collected += season.extras.map {
                    OwnedExtra(extra: $0, ownerLabel: label, isDirect: false)
                }
                for episode in season.episodes {
                    collected += episode.extras.map {
                        OwnedExtra(extra: $0, ownerLabel: episode.identityLabel, isDirect: false)
                    }
                }
            }
            return collected
        }
    }

    /// How an extra is filed. Every recognised folder is a case whether or not it
    /// currently holds anything, because the list is also the set of places an
    /// extra can be dropped.
    public enum Filing: Sendable, Hashable {
        case folder(String)
        /// Bound by a filename suffix, so it sits in no extras folder.
        case filenameSuffix
    }

    public static func filing(of extra: Extra) -> Filing {
        if let folderName = extra.folderName { .folder(folderName) } else { .filenameSuffix }
    }

    /// Counts for every canonical folder, in Emby's documented order, plus the
    /// suffix bucket. Folders holding nothing come back with a count of zero
    /// rather than being omitted.
    public static func countsByFolder(_ extras: [OwnedExtra]) -> (
        folders: [(folder: ExtrasFolder, count: Int)],
        suffixCount: Int
    ) {
        var counts: [String: Int] = [:]
        var suffixCount = 0

        for owned in extras {
            switch filing(of: owned.extra) {
            case .folder(let name): counts[name, default: 0] += 1
            case .filenameSuffix: suffixCount += 1
            }
        }

        return (
            folders: ExtrasFolder.all.map { (folder: $0, count: counts[$0.name] ?? 0) },
            suffixCount: suffixCount
        )
    }

    /// Counts per type, for a type list that only offers types actually present.
    public static func countsByType(_ extras: [OwnedExtra]) -> [(type: ExtraType, count: Int)] {
        Dictionary(grouping: extras, by: \.extra.type)
            .map { (type: $0.key, count: $0.value.count) }
            .sorted { lhs, rhs in
                lhs.count == rhs.count
                    ? lhs.type.displayName < rhs.type.displayName
                    : lhs.count > rhs.count
            }
    }

    static func seasonLabel(_ number: Int) -> String {
        number == 0 ? "Specials" : "Season \(number)"
    }
}
