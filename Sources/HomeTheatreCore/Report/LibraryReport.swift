import Foundation

/// Renders a resolved library as plain text.
///
/// This is the read-only half of the tool made visible: everything the editor will
/// eventually let you drag around, printed in the order a client would show it.
public struct LibraryReport: Sendable {
    public var includeExtras: Bool
    public var includeUnassigned: Bool

    public init(includeExtras: Bool = true, includeUnassigned: Bool = true) {
        self.includeExtras = includeExtras
        self.includeUnassigned = includeUnassigned
    }

    public func render(_ result: LibraryScanResult) -> String {
        let resolver = DisplayOrderResolver()
        var out = ""

        out += "Path:    \(result.root.path)\n"
        out += "Read as: \(result.mode.description)\n"
        out += "Series:  \(result.series.count)\n"

        let episodeCount = result.series.reduce(0) { $0 + $1.allEpisodes.count }
        let extraCount = result.series.reduce(0) { partial, series in
            partial + series.extras.count
                + series.seasons.reduce(0) { $0 + $1.extras.count + $1.episodes.reduce(0) { $0 + $1.extras.count } }
        }
        out += "Episodes: \(episodeCount)   Extras: \(extraCount)\n"

        for series in result.series {
            out += "\n" + String(repeating: "=", count: 72) + "\n"
            out += render(resolver.resolve(series))
        }

        if !result.warnings.isEmpty {
            out += "\n" + String(repeating: "=", count: 72) + "\n"
            out += "Warnings (\(result.warnings.count))\n"
            for warning in result.warnings {
                out += "  ! \(warning)\n"
            }
        }
        return out
    }

    public func render(_ resolved: ResolvedSeries) -> String {
        let series = resolved.series
        var out = "\(series.name)\n"

        var attributes: [String] = []
        attributes.append("display order: \(series.displayOrder?.rawValue ?? "aired (default)")")
        if !series.providerIds.isEmpty {
            attributes.append(series.providerIds.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
        }
        if series.nfoURL == nil { attributes.append("no tvshow.nfo") }
        out += "  " + attributes.joined(separator: "   ") + "\n"

        if includeExtras && !series.extras.isEmpty {
            out += "\n  Series extras\n"
            out += renderExtras(series.extras, indent: "    ")
        }

        // Display seasons are derived, so they need not line up with the seasons on
        // disk: a specials folder whose episodes are all placed elsewhere leaves no
        // display season behind. Track which scanned seasons have had their extras
        // shown so the leftovers can be reported rather than silently dropped.
        var emittedExtrasFor: Set<Int> = []

        for season in resolved.seasons {
            let label = season.number == 0 ? "Specials" : "Season \(season.number)"
            out += "\n  ── \(label) ── (\(season.episodes.count))\n"

            if let scanned = series.seasons.first(where: { $0.number == season.number }) {
                var notes: [String] = []
                if let title = scanned.title { notes.append("\"\(title)\"") }
                notes.append(scanned.nfoURL == nil ? "no season.nfo" : "season.nfo")
                if scanned.locked { notes.append("locked") }
                if scanned.numberOverriddenByNFO, let folderNumber = scanned.folderNumber {
                    notes.append("folder says \(folderNumber), season.nfo says \(scanned.number)")
                }
                out += "     " + notes.joined(separator: "   ") + "\n"
            }

            for resolvedEpisode in season.episodes {
                out += renderEpisode(resolvedEpisode)
            }

            if includeExtras,
               let scanned = series.seasons.first(where: { $0.number == season.number }),
               !scanned.extras.isEmpty {
                out += "\n    \(label) extras\n"
                out += renderExtras(scanned.extras, indent: "      ")
                emittedExtrasFor.insert(season.number)
            }
        }

        if includeExtras {
            for scanned in series.seasons where !emittedExtrasFor.contains(scanned.number) && !scanned.extras.isEmpty {
                let label = scanned.isSpecials ? "Specials" : "Season \(scanned.number)"
                out += "\n  \(label) extras — this season has no episodes left in the display order\n"
                out += renderExtras(scanned.extras, indent: "    ")
            }
        }

        if includeUnassigned && !series.unassigned.isEmpty {
            out += "\n  Unassigned (\(series.unassigned.count)) — no episode numbering, no extras folder\n"
            for file in series.unassigned {
                out += "    ? \(file.lastPathComponent)\n"
            }
        }
        return out
    }

    private func renderExtras(_ extras: [Extra], indent: String) -> String {
        extras
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            .map { "\(indent)· [\($0.type.displayName)] \($0.title)\n" }
            .joined()
    }

    private func renderEpisode(_ resolved: ResolvedEpisode) -> String {
        let episode = resolved.episode
        let position = String(format: "%3d.", resolved.effectiveNumber)
        let identity = episode.identityLabel.padding(toLength: 12, withPad: " ", startingAt: 0)
        let title = (episode.title ?? episode.file.lastPathComponent)
            .padding(toLength: 46, withPad: " ", startingAt: 0)

        var flags: [String] = []
        switch resolved.source {
        case .pinned:
            let season = episode.displaySeason.map(String.init) ?? "–"
            let number = episode.displayNumber.map(String.init) ?? "–"
            flags.append("pinned \(season)x\(number)")
        case .inherited:
            flags.append("inherited")
        }
        if resolved.isRelocated { flags.append("moved from S\(episode.season ?? 0)") }
        if episode.locked { flags.append("locked") }
        if episode.nfoURL == nil { flags.append("no nfo") }

        var out = "  \(position) \(identity) \(title) [\(flags.joined(separator: ", "))]\n"
        out += renderExtras(episode.extras, indent: "        ")
        return out
    }
}
