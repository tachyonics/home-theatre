import Foundation

/// Typed reads of the NFO tags that carry structure, faithful to how Emby's
/// `NfoMetadata` plugin parses them.
///
/// Two rules from that parser are load-bearing and easy to get wrong:
///
/// 1. **Five tags, two properties.** `<displayseason>`, `<airsbefore_season>` and
///    `<airsafter_season>` all write the same sort-parent property;
///    `<displayepisode>` and `<airsbefore_episode>` both write the same sort-index
///    property. Emby draws no distinction between "airs before" and "airs after" at
///    the field level — placement is decided by the pair of values. Because they
///    share a destination, **document order decides**: the last one wins.
///
/// 2. **Values must be > 0.** Zero and negatives are silently discarded, which is
///    why nothing can be positioned ahead of episode 1 of a display season without
///    renumbering that season's display sequence.
public enum NFOFields {
    static let sortParentTags = ["displayseason", "airsbefore_season", "airsafter_season"]
    static let sortIndexTags = ["displayepisode", "airsbefore_episode"]

    /// Emby discards non-positive values for every ordering tag.
    static func positive(_ raw: String?) -> Int? {
        guard let raw, let value = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)), value > 0 else {
            return nil
        }
        return value
    }

    /// Walks children in document order so that aliasing tags resolve the same way
    /// Emby's parser resolves them — last assignment wins.
    static func resolveOrderingPair(_ root: NFOElement) -> (parent: Int?, index: Int?) {
        var parent: Int?
        var index: Int?
        for child in root.children {
            let name = child.name.lowercased()
            if sortParentTags.contains(name) {
                if let value = positive(child.trimmedText) { parent = value }
            } else if sortIndexTags.contains(name) {
                if let value = positive(child.trimmedText) { index = value }
            }
        }
        return (parent, index)
    }

    static let providerTags: [String: String] = [
        "tvdbid": "Tvdb",
        "tmdbid": "Tmdb",
        "imdbid": "Imdb",
        "imdb_id": "Imdb",
        "id": "Tvdb",
    ]

    static func providerIds(_ root: NFOElement) -> [String: String] {
        var ids: [String: String] = [:]
        for child in root.children {
            guard let key = providerTags[child.name.lowercased()] else { continue }
            let value = child.trimmedText
            guard !value.isEmpty else { continue }
            // An explicit `<tvdbid>` should beat a generic `<id>`.
            if child.name.lowercased() == "id", ids[key] != nil { continue }
            ids[key] = value
        }
        for unique in root.children(where: "uniqueid") {
            guard let type = unique.attributes["type"], !unique.trimmedText.isEmpty else { continue }
            ids[type.capitalized] = unique.trimmedText
        }
        return ids
    }

    /// Applies the `<episodedetails>` structural fields onto an episode.
    public static func applyEpisode(_ doc: NFODocument, to episode: inout Episode) {
        let root = doc.root
        episode.season = root.int("season") ?? episode.season
        episode.number = root.int("episode") ?? episode.number
        episode.numberEnd = root.int("episodenumberend") ?? episode.numberEnd
        episode.title = root.string("title") ?? episode.title
        episode.locked = root.bool("lockdata") ?? episode.locked

        let ordering = resolveOrderingPair(root)
        episode.displaySeason = ordering.parent
        episode.displayNumber = ordering.index

        let ids = providerIds(root)
        if !ids.isEmpty { episode.providerIds = ids }
    }

    /// Applies the `<tvshow>` fields onto a series.
    public static func applySeries(_ doc: NFODocument, to series: inout Series) {
        let root = doc.root
        if let raw = root.string("displayorder") {
            series.displayOrder = SeriesDisplayOrder(nfoValue: raw)
        }
        let ids = providerIds(root)
        if !ids.isEmpty { series.providerIds = ids }
    }
}

extension NFOElement {
    func children(where name: String) -> [NFOElement] {
        children.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }
}
