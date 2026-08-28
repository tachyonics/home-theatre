import Foundation

/// Walks a TV library and reconstructs the structure Emby would derive from it.
///
/// The scan is deliberately an *interpretation*, not an import: given the same
/// tree, it should produce the same episode/extra/ordering assignments Emby does,
/// so that loading and re-serialising a series yields no changes. That round-trip
/// is the correctness test for this type — any spurious diff is a rule this
/// scanner has wrong.
public struct LibraryScanner: Sendable {
    public var followSymlinks: Bool

    public init(followSymlinks: Bool = false) {
        self.followSymlinks = followSymlinks
    }

    public func scan(root: URL) throws -> LibraryScanResult {
        var warnings: [String] = []

        if try looksLikeSeriesFolder(root) {
            let series = try scanSeries(folder: root, warnings: &warnings)
            return LibraryScanResult(root: root, mode: .singleSeries, series: [series], warnings: warnings)
        }

        var series: [Series] = []
        for folder in try subdirectories(of: root) {
            do {
                series.append(try scanSeries(folder: folder, warnings: &warnings))
            } catch {
                warnings.append("\(folder.lastPathComponent): \(error)")
            }
        }

        series.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return LibraryScanResult(root: root, mode: .library, series: series, warnings: warnings)
    }

    /// A series folder announces itself three ways: a `tvshow.nfo`, season
    /// sub-folders holding numbered episodes, or numbered episodes sitting loose.
    /// A library root has none of these — its children are series names.
    func looksLikeSeriesFolder(_ folder: URL) throws -> Bool {
        if FileManager.default.fileExists(atPath: folder.appendingPathComponent("tvshow.nfo").path) {
            return true
        }
        for child in try subdirectories(of: folder) {
            if FilenameParser.seasonNumber(fromFolderName: child.lastPathComponent) != nil,
               try folderContainsNumberedEpisodes(child) {
                return true
            }
        }
        return try folderContainsNumberedEpisodes(folder)
    }

    // MARK: - Series

    func scanSeries(folder: URL, warnings: inout [String]) throws -> Series {
        var series = Series(name: folder.lastPathComponent, folder: folder)

        let nfoURL = folder.appendingPathComponent("tvshow.nfo")
        if FileManager.default.fileExists(atPath: nfoURL.path) {
            series.nfoURL = nfoURL
            if let doc = try? NFODocument.parse(contentsOf: nfoURL) {
                NFOFields.applySeries(doc, to: &series)
            } else {
                warnings.append("\(folder.lastPathComponent)/tvshow.nfo could not be parsed")
            }
        }

        var seasons: [Int: Season] = [:]

        for child in try subdirectories(of: folder) {
            let name = child.lastPathComponent

            // `Specials` is both a season-0 folder name and an extras folder name.
            // Emby tells them apart by what is inside: SxxExx-named files make it a
            // season. Season detection therefore has to be confirmed by content.
            if let number = FilenameParser.seasonNumber(fromFolderName: name),
               try folderContainsNumberedEpisodes(child) {
                let season = try scanSeason(folder: child, folderNumber: number, warnings: &warnings)
                insert(season, into: &seasons, series: series.name, warnings: &warnings)
                continue
            }

            if let type = FilenameParser.extrasFolderType(fromFolderName: name) {
                series.extras += try extras(in: child, type: type, parent: .series)
                continue
            }

            if let number = FilenameParser.seasonNumber(fromFolderName: name) {
                // Looked like a season but held no numbered episodes.
                warnings.append("\(name) in \(series.name) looks like a season but contains no SxxExx files")
                let season = try scanSeason(folder: child, folderNumber: number, warnings: &warnings)
                insert(season, into: &seasons, series: series.name, warnings: &warnings)
                continue
            }

            series.unassigned += try videoFiles(in: child, recursive: true)
        }

        // Episodes can sit directly in the series folder with no season sub-folders
        // at all. Group those by season rather than dumping them as unassigned.
        var looseEpisodes: [Episode] = []
        var looseSuffixExtras: [(FilenameParser.SuffixExtra, URL)] = []

        for file in try videoFiles(in: folder, recursive: false) {
            if let suffix = FilenameParser.suffixExtra(fromFilename: file.lastPathComponent) {
                looseSuffixExtras.append((suffix, file))
            } else if let numbering = FilenameParser.episodeNumbering(from: file.lastPathComponent) {
                looseEpisodes.append(makeEpisode(file: file, numbering: numbering))
            } else {
                series.unassigned.append(file)
            }
        }

        for (suffix, file) in looseSuffixExtras {
            let ownerStem = suffix.ownerStem.lowercased()
            if let index = looseEpisodes.firstIndex(where: {
                $0.file.deletingPathExtension().lastPathComponent.lowercased() == ownerStem
            }) {
                let owner = looseEpisodes[index]
                looseEpisodes[index].extras.append(
                    Extra(
                        file: file,
                        type: suffix.type,
                        parent: .episode(season: owner.season ?? 0, number: owner.number ?? 0),
                        title: FilenameParser.extraTitle(for: file)
                    )
                )
            } else {
                series.unassigned.append(file)
            }
        }

        for (number, grouped) in Dictionary(grouping: looseEpisodes, by: { $0.season ?? 0 }) {
            let loose = Season(
                number: number,
                folder: folder,
                episodes: grouped.sorted { ($0.number ?? 0) < ($1.number ?? 0) }
            )
            insert(loose, into: &seasons, series: series.name, warnings: &warnings)
        }

        series.seasons = seasons.values.sorted { $0.number < $1.number }
        return series
    }

    // MARK: - Season

    func scanSeason(folder: URL, folderNumber: Int, warnings: inout [String]) throws -> Season {
        var season = Season(number: folderNumber, folderNumber: folderNumber, folder: folder)

        let nfoURL = folder.appendingPathComponent("season.nfo")
        if FileManager.default.fileExists(atPath: nfoURL.path) {
            season.nfoURL = nfoURL
            if let doc = try? NFODocument.parse(contentsOf: nfoURL) {
                NFOFields.applySeason(doc, to: &season)
            } else {
                warnings.append("\(folder.lastPathComponent)/season.nfo could not be parsed")
            }
        }

        if season.numberOverriddenByNFO {
            warnings.append(
                "\(folder.lastPathComponent) is season \(season.number) per season.nfo, not \(folderNumber) per the folder name"
            )
        }

        // Everything below keys off the effective number, not the folder name.
        let number = season.number

        var episodes: [Episode] = []
        var suffixExtras: [(FilenameParser.SuffixExtra, URL)] = []

        for file in try videoFiles(in: folder, recursive: false) {
            if let suffix = FilenameParser.suffixExtra(fromFilename: file.lastPathComponent) {
                suffixExtras.append((suffix, file))
                continue
            }
            guard let numbering = FilenameParser.episodeNumbering(from: file.lastPathComponent) else {
                warnings.append("\(file.lastPathComponent) in \(folder.lastPathComponent) has no episode numbering")
                continue
            }
            episodes.append(makeEpisode(file: file, numbering: numbering))
        }

        // Sub-folders: extras for the season, or an SxxExx folder holding one episode.
        for child in try subdirectories(of: folder) {
            let name = child.lastPathComponent

            if let numbering = FilenameParser.episodeFolderNumbering(fromFolderName: name) {
                for file in try videoFiles(in: child, recursive: false) {
                    if let suffix = FilenameParser.suffixExtra(fromFilename: file.lastPathComponent) {
                        suffixExtras.append((suffix, file))
                    } else if let inner = FilenameParser.episodeNumbering(from: file.lastPathComponent) {
                        episodes.append(makeEpisode(file: file, numbering: inner))
                    } else {
                        episodes.append(makeEpisode(file: file, numbering: numbering))
                    }
                }
                for grandchild in try subdirectories(of: child) {
                    guard let type = FilenameParser.extrasFolderType(fromFolderName: grandchild.lastPathComponent) else { continue }
                    season.extras += try extras(
                        in: grandchild,
                        type: type,
                        parent: .episode(season: numbering.season, number: numbering.number)
                    )
                }
                continue
            }

            if let type = FilenameParser.extrasFolderType(fromFolderName: name) {
                season.extras += try extras(in: child, type: type, parent: .season(number))
            }
        }

        // Bind suffix extras to the episode sharing their stem; anything unmatched
        // degrades to a season-level extra rather than being dropped.
        for (suffix, file) in suffixExtras {
            let ownerStem = suffix.ownerStem.lowercased()
            if let index = episodes.firstIndex(where: {
                $0.file.deletingPathExtension().lastPathComponent.lowercased() == ownerStem
            }) {
                let episode = episodes[index]
                episodes[index].extras.append(
                    Extra(
                        file: file,
                        type: suffix.type,
                        parent: .episode(season: episode.season ?? number, number: episode.number ?? 0),
                        title: FilenameParser.extraTitle(for: file)
                    )
                )
            } else {
                warnings.append("\(file.lastPathComponent) has no matching episode file; treated as a season extra")
                season.extras.append(
                    Extra(file: file, type: suffix.type, parent: .season(number), title: FilenameParser.extraTitle(for: file))
                )
            }
        }

        // Extras found inside an SxxExx folder name an episode as their parent, so
        // move them onto that episode rather than leaving them on the season.
        var seasonExtras: [Extra] = []
        for extra in season.extras {
            guard case let .episode(episodeSeason, episodeNumber) = extra.parent,
                  let index = episodes.firstIndex(where: {
                      ($0.season ?? number) == episodeSeason && $0.number == episodeNumber
                  })
            else {
                seasonExtras.append(extra)
                continue
            }
            episodes[index].extras.append(extra)
        }
        season.extras = seasonExtras

        episodes.sort { ($0.number ?? 0) < ($1.number ?? 0) }
        season.episodes = episodes
        return season
    }

    /// Two folders can end up claiming the same season once `<seasonnumber>` is
    /// honoured. Merge rather than silently dropping one of them.
    private func insert(_ season: Season, into seasons: inout [Int: Season], series: String, warnings: inout [String]) {
        guard var existing = seasons[season.number] else {
            seasons[season.number] = season
            return
        }
        warnings.append(
            "\(series): \(existing.folder.lastPathComponent) and \(season.folder.lastPathComponent) both resolve to season \(season.number); merged"
        )
        existing.episodes += season.episodes
        existing.extras += season.extras
        existing.episodes.sort { ($0.number ?? 0) < ($1.number ?? 0) }
        seasons[season.number] = existing
    }

    private func makeEpisode(file: URL, numbering: FilenameParser.EpisodeNumbering) -> Episode {
        var episode = Episode(
            file: file,
            season: numbering.season,
            number: numbering.number,
            numberEnd: numbering.numberEnd,
            title: file.deletingPathExtension().lastPathComponent
        )

        let nfoURL = file.deletingPathExtension().appendingPathExtension("nfo")
        if FileManager.default.fileExists(atPath: nfoURL.path) {
            episode.nfoURL = nfoURL
            if let doc = try? NFODocument.parse(contentsOf: nfoURL) {
                NFOFields.applyEpisode(doc, to: &episode)
            }
        }
        return episode
    }

    // MARK: - Filesystem helpers

    private func extras(in folder: URL, type: ExtraType, parent: ExtraParent) throws -> [Extra] {
        try videoFiles(in: folder, recursive: false).map { file in
            Extra(file: file, type: type, parent: parent, title: FilenameParser.extraTitle(for: file))
        }
    }

    private func contents(of folder: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ).sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    private func subdirectories(of folder: URL) throws -> [URL] {
        try contents(of: folder).filter { url in
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values?.isSymbolicLink == true && !followSymlinks { return false }
            return values?.isDirectory == true
        }
    }

    private func videoFiles(in folder: URL, recursive: Bool) throws -> [URL] {
        var results: [URL] = []
        for url in try contents(of: folder) {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values?.isSymbolicLink == true && !followSymlinks { continue }
            if values?.isDirectory == true {
                if recursive { results += try videoFiles(in: url, recursive: true) }
            } else if FilenameParser.isVideo(url) {
                results.append(url)
            }
        }
        return results
    }

    private func folderContainsNumberedEpisodes(_ folder: URL) throws -> Bool {
        for url in try contents(of: folder) where FilenameParser.isVideo(url) {
            if FilenameParser.suffixExtra(fromFilename: url.lastPathComponent) != nil { continue }
            if FilenameParser.episodeNumbering(from: url.lastPathComponent) != nil { return true }
        }
        // An SxxExx sub-folder also makes this a season.
        for child in try subdirectories(of: folder) {
            if FilenameParser.episodeFolderNumbering(fromFolderName: child.lastPathComponent) != nil { return true }
        }
        return false
    }
}
