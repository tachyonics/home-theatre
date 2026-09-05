import Foundation

/// Turning an episode into an extra of its season.
///
/// The rule this encodes is the one ``ExtrasFolder`` already states: placing an
/// extra means moving a file into one of the recognised folders. There is no
/// metadata to write — an extra's type comes from the folder it sits in, and Emby
/// has no field for it — so reclassifying an episode is *entirely* a matter of
/// moving files, which is why this is expressible with file steps alone.
public enum ExtrasFiling {
    /// One action: reclassify `episode` as an extra of the given folder.
    ///
    /// An episode is rarely one file. Its NFO, its `-thumb`, and its external
    /// subtitle tracks are bound to it by filename, so leaving them behind would
    /// not leave them working — it would leave them referring to a video that is no
    /// longer their sibling, which the scanner then attributes to nothing at all.
    /// They move as steps of the one action, never separately. The NFO travels too:
    /// it is inert once the file is an extra, but deleting it would throw away the
    /// only record of the episode's identity, and dragging the file back should be
    /// able to restore it.
    ///
    /// Returns nil when there is nothing to do, so a drop onto the folder a file is
    /// already in queues nothing rather than an action that would do nothing.
    public static func action(
        episode: Episode,
        in season: Season,
        folder: ExtrasFolder
    ) -> PendingAction? {
        let destination = season.folder.appendingPathComponent(folder.name, isDirectory: true)

        var sources = [episode.file]
        if let nfoURL = episode.nfoURL { sources.append(nfoURL) }
        sources.append(contentsOf: episode.assets.map(\.file))

        var seen = Set<URL>()
        let steps: [FileStep] = sources.compactMap { source in
            // A season image filed up in the series folder can appear on more than
            // one entity, and a file already sitting in the destination has nowhere
            // to go — neither should produce a step.
            guard seen.insert(source.standardizedFileURL).inserted else { return nil }
            let target = destination.appendingPathComponent(source.lastPathComponent)
            guard target.standardizedFileURL != source.standardizedFileURL else { return nil }
            return .move(from: source, to: target)
        }

        guard !steps.isEmpty else { return nil }

        return PendingAction(
            // The type is what the user chose; the folder is what disambiguates it,
            // since `extras` and `specials` are both "Extra".
            title: "Set as \(folder.type.displayName) extra",
            detail: "into \(season.folder.lastPathComponent)/\(folder.name)/",
            steps: steps
        )
    }
}
