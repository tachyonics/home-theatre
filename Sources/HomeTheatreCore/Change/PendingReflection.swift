import Foundation

/// A queued filing, projected back onto the library it was made against.
///
/// The queue holds decisions; the browser shows a tree. Something has to say what
/// the tree *would* look like, and doing that in the views would put the rule for
/// where an extra lands in two places — once in ``ExtrasFiling``, which moves the
/// files, and again in whatever draws the preview. The two would drift, and the
/// preview would then be a confident lie. So the projection lives beside the rule
/// it mirrors, and both read the destination off the same expression.
///
/// Everything here describes the library *before* the action is applied. The
/// episode is still an episode, still where it was; only ``destination`` and
/// ``futureExtra`` speak about afterwards.
public struct PendingFiling: Sendable, Hashable, Identifiable {
    public var action: PendingAction
    /// Where the episode currently lives — the scope a view filters against, since
    /// an extras folder belongs to a season and a season belongs to a series.
    public var series: Series
    public var season: Season
    public var episode: Episode
    public var folder: ExtrasFolder
    /// Which of the two the extra is being filed under. Both are ancestors of the
    /// episode, so this picks between them rather than naming a third thing.
    public var owner: ExtrasOwner

    /// The action's, so a row previewing a change and the queue row for it are the
    /// same thing under two views.
    public var id: UUID { action.id }

    public init(
        action: PendingAction,
        series: Series,
        season: Season,
        episode: Episode,
        folder: ExtrasFolder,
        owner: ExtrasOwner
    ) {
        self.action = action
        self.series = series
        self.season = season
        self.episode = episode
        self.folder = folder
        self.owner = owner
    }

    /// The folder the extras sub-folder sits in — the owning item's own folder.
    public var ownerFolder: URL {
        switch owner {
        case .series: series.folder
        case .season: season.folder
        }
    }

    /// Where the video will sit once applied.
    ///
    /// The same expression ``ExtrasFiling`` builds its move steps from — under the
    /// item the filing named, never under whatever the user has since selected.
    public var destination: URL {
        ownerFolder
            .appendingPathComponent(folder.name, isDirectory: true)
            .appendingPathComponent(episode.file.lastPathComponent)
    }

    /// The extra a rescan would find after applying, built to match what
    /// ``LibraryScanner`` produces for a file in an extras folder: the type comes
    /// from the folder, the title from the filename stem, and the parent is the
    /// item whose folder contains it.
    ///
    /// Matching the scanner exactly is the point — a preview that differs from the
    /// result is worse than no preview, so the two are asserted equal in the tests.
    public var futureExtra: Extra {
        Extra(
            file: destination,
            type: folder.type,
            parent: owner == .series ? .series : .season(season.number),
            title: destination.deletingPathExtension().lastPathComponent,
            folderName: folder.name
        )
    }
}

extension ChangeSet {
    /// Every queued filing that still names something in this scan.
    ///
    /// Actions whose episode cannot be found are dropped rather than reported: ids
    /// are issued per scan, so an action from a previous one resolves to nothing,
    /// and a preview is the wrong place to raise that — the queue itself already
    /// guards rescans against it.
    public func pendingFilings(in result: LibraryScanResult) -> [PendingFiling] {
        allActions.compactMap { entity, action in
            guard case .fileEpisodeAsExtra(let folder, let owner) = action.intent,
                  let location = result.locate(episode: entity.id)
            else { return nil }

            return PendingFiling(
                action: action,
                series: location.series,
                season: location.season,
                episode: location.episode,
                folder: folder,
                owner: owner
            )
        }
    }
}

extension LibraryScanResult {
    /// The library as it will read once these filings have been applied.
    ///
    /// A queued filing is shown where it *will* be rather than where it still is:
    /// the episode leaves its season and turns up inside the extras folder it was
    /// dropped on. That is the point of previewing at all — the user asked for an
    /// outcome, and a browser that keeps drawing the old shape with a badge stuck
    /// on it makes them hold the change in their head. Only the badge says it has
    /// not happened yet.
    ///
    /// Entity ids are carried across, so a projected library still answers
    /// ``locate(episode:)`` for everything that has not been filed. Queueing must
    /// still be done against the real scan: this one describes a disk that does not
    /// exist yet, and steps built from it would move files that are not there.
    public func applyingPendingFilings(_ filings: [PendingFiling]) -> LibraryScanResult {
        guard !filings.isEmpty else { return self }

        let filed = Set(filings.map(\.episode.id))
        // Grouped by the item each lands on, not by the one it came from: a filing
        // made against the series leaves its season the same way, but the extra it
        // produces belongs a level up.
        let arrivingAtSeason = Dictionary(
            grouping: filings.filter { $0.owner == .season },
            by: \.season.id
        ).mapValues { $0.map(\.futureExtra) }
        let arrivingAtSeries = Dictionary(
            grouping: filings.filter { $0.owner == .series },
            by: \.series.id
        ).mapValues { $0.map(\.futureExtra) }

        var projected = self
        projected.series = series.map { series in
            var series = series
            series.seasons = series.seasons.map { season in
                var season = season
                let leaving = season.episodes.filter { filed.contains($0.id) }
                season.episodes.removeAll { filed.contains($0.id) }
                // A suffix-bound extra is not part of the filing and does not move
                // with it, so applying leaves it naming a video that is no longer
                // its sibling — which is exactly the season extra the next scan
                // makes of it. Showing that now is what stops the preview being
                // rosier than the result.
                season.extras += leaving.flatMap(\.extras)
                season.extras += arrivingAtSeason[season.id] ?? []
                return season
            }
            series.extras += arrivingAtSeries[series.id] ?? []
            return series
        }
        return projected
    }
}
