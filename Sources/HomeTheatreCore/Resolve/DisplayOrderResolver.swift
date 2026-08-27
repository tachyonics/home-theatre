import Foundation

/// One episode's position in the sequence a client would actually render.
public struct ResolvedEpisode: Sendable, Hashable {
    public var episode: Episode
    /// The season bucket this appears under once display numbering is applied.
    public var effectiveSeason: Int
    /// Position within that bucket.
    public var effectiveNumber: Int
    public var source: DisplaySource

    /// True when display numbering moves this item out of its identity season —
    /// a special interleaved into the run of ordinary seasons, typically.
    public var isRelocated: Bool {
        effectiveSeason != (episode.season ?? effectiveSeason)
    }
}

public struct ResolvedSeason: Sendable, Hashable {
    public var number: Int
    public var episodes: [ResolvedEpisode]
}

public struct ResolvedSeries: Sendable, Hashable {
    public var series: Series
    public var seasons: [ResolvedSeason]

    public var episodeCount: Int { seasons.reduce(0) { $0 + $1.episodes.count } }
}

/// Derives the sequence a client renders, from identity numbering plus whatever
/// display numbering is present.
///
/// Most episodes carry no display numbering at all and inherit their position from
/// `<season>`/`<episode>`. Only pinned items — in practice the specials Emby has
/// placed from TVDB's airs-before/airs-after data — carry it explicitly. The
/// resolver's job is to produce a total order from that partial specification,
/// which is what the editor then lets you rearrange.
public struct DisplayOrderResolver: Sendable {
    public init() {}

    public func resolve(_ series: Series) -> ResolvedSeries {
        var buckets: [Int: [ResolvedEpisode]] = [:]

        for episode in series.allEpisodes {
            let identitySeason = episode.season ?? 0
            let identityNumber = episode.number ?? 0
            let effectiveSeason = episode.displaySeason ?? identitySeason
            let effectiveNumber = episode.displayNumber ?? identityNumber

            buckets[effectiveSeason, default: []].append(
                ResolvedEpisode(
                    episode: episode,
                    effectiveSeason: effectiveSeason,
                    effectiveNumber: effectiveNumber,
                    source: episode.displaySource
                )
            )
        }

        let seasons = buckets.keys.sorted().map { number in
            ResolvedSeason(number: number, episodes: buckets[number, default: []].sorted(by: Self.order))
        }
        return ResolvedSeries(series: series, seasons: seasons)
    }

    /// Ties are broken so the ordering is stable and reproducible rather than
    /// dependent on scan order: position, then identity season, then identity
    /// number, then filename.
    static func order(_ lhs: ResolvedEpisode, _ rhs: ResolvedEpisode) -> Bool {
        if lhs.effectiveNumber != rhs.effectiveNumber {
            return lhs.effectiveNumber < rhs.effectiveNumber
        }
        let lhsSeason = lhs.episode.season ?? 0
        let rhsSeason = rhs.episode.season ?? 0
        if lhsSeason != rhsSeason { return lhsSeason < rhsSeason }
        let lhsNumber = lhs.episode.number ?? 0
        let rhsNumber = rhs.episode.number ?? 0
        if lhsNumber != rhsNumber { return lhsNumber < rhsNumber }
        return lhs.episode.file.lastPathComponent < rhs.episode.file.lastPathComponent
    }
}
