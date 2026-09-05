import Foundation

extension LibraryScanResult {
    /// An episode together with what contains it.
    ///
    /// The season is the part that matters to callers: an extras folder sits
    /// directly under the item's own folder, and an episode has no folder of its
    /// own, so filing one as an extra means filing it under the season that holds
    /// it — not under whatever the user happens to have selected.
    public struct EpisodeLocation: Sendable {
        public var series: Series
        public var season: Season
        public var episode: Episode
    }

    /// Finds an episode by the id its scan gave it.
    ///
    /// A linear walk: a library is thousands of episodes at most, and this runs on
    /// a drop, so an index would be machinery bought for nothing.
    public func locate(episode id: UUID) -> EpisodeLocation? {
        for series in series {
            for season in series.seasons {
                if let episode = season.episodes.first(where: { $0.id == id }) {
                    return EpisodeLocation(series: series, season: season, episode: episode)
                }
            }
        }
        return nil
    }
}

extension Episode {
    /// `S01E03`, falling back to the filename when the episode carries no identity
    /// numbering — an unmatched file still has to be nameable in a change list.
    public var entityLabel: String {
        guard season != nil, number != nil else { return file.lastPathComponent }
        return identityLabel
    }

}

extension LibraryScanResult.EpisodeLocation {
    /// `Doctor Who (2005) — S01E03`. Named from here rather than from the episode
    /// alone because a review list spanning several series needs to say which one.
    public var entityRef: EntityRef {
        EntityRef(
            id: episode.id,
            level: .episode,
            label: "\(series.name) — \(episode.entityLabel)"
        )
    }
}
