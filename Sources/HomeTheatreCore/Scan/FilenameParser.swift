import Foundation

public enum FilenameParser {
    public static let videoExtensions: Set<String> = [
        "mkv", "mp4", "m4v", "avi", "mov", "ts", "m2ts", "mpg", "mpeg", "wmv", "flv", "webm", "iso",
    ]

    public static func isVideo(_ url: URL) -> Bool {
        videoExtensions.contains(url.pathExtension.lowercased())
    }

    public struct EpisodeNumbering: Sendable, Hashable {
        public var season: Int
        public var number: Int
        public var numberEnd: Int?
    }

    /// `S01E02`, `S01E02-E03`, `S01E02E03`, `1x02`, `s01.e02`.
    ///
    /// Deliberately conservative: this only claims files whose numbering is
    /// unambiguous. Anything looser belongs to a real parser (guessit and friends)
    /// rather than a hand-rolled regex, and unmatched files land in the
    /// unassigned bin where they can be placed by hand.
    private static let episodePatterns: [NSRegularExpression] = {
        let sources = [
            #"[sS](\d{1,4})[\s._-]*[eE](\d{1,4})(?:[\s._-]*(?:[eE]|-)\s*[eE]?(\d{1,4}))?"#,
            #"(?<![a-zA-Z0-9])(\d{1,2})[xX](\d{1,3})(?:[-xX](\d{1,3}))?(?![a-zA-Z0-9])"#,
        ]
        return sources.compactMap { try? NSRegularExpression(pattern: $0) }
    }()

    public static func episodeNumbering(from filename: String) -> EpisodeNumbering? {
        let range = NSRange(filename.startIndex..<filename.endIndex, in: filename)
        for pattern in episodePatterns {
            guard let match = pattern.firstMatch(in: filename, range: range) else { continue }
            func group(_ index: Int) -> Int? {
                guard index < match.numberOfRanges,
                      let r = Range(match.range(at: index), in: filename) else { return nil }
                return Int(filename[r])
            }
            guard let season = group(1), let number = group(2) else { continue }
            let end = group(3)
            return EpisodeNumbering(season: season, number: number, numberEnd: end == number ? nil : end)
        }
        return nil
    }

    /// `Season 3`, `Season 03`, `Specials`, `Season 0`, `S3`.
    ///
    /// Note that `Specials` is claimed here *and* is a valid extras folder name.
    /// The scanner disambiguates by looking at what is inside: a folder holding
    /// `SxxExx`-named files is a season, otherwise it is an extras folder. Emby's
    /// own documentation shows both readings in a single tree.
    public static func seasonNumber(fromFolderName name: String) -> Int? {
        let lowered = name.lowercased().trimmingCharacters(in: .whitespaces)
        if lowered == "specials" || lowered == "season 0" || lowered == "season 00" { return 0 }
        let patterns = [#"^season[\s._-]*(\d{1,4})$"#, #"^s(\d{1,4})$"#]
        for source in patterns {
            guard let regex = try? NSRegularExpression(pattern: source, options: .caseInsensitive) else { continue }
            let range = NSRange(lowered.startIndex..<lowered.endIndex, in: lowered)
            if let match = regex.firstMatch(in: lowered, range: range),
               let r = Range(match.range(at: 1), in: lowered) {
                return Int(lowered[r])
            }
        }
        return nil
    }

    /// An `SxxExx`-named folder holding one episode plus its extras folders.
    public static func episodeFolderNumbering(fromFolderName name: String) -> EpisodeNumbering? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard let numbering = episodeNumbering(from: trimmed) else { return nil }
        // Guard against a folder that merely mentions an episode in prose.
        return trimmed.count <= 24 ? numbering : nil
    }

    public static func extrasFolderType(fromFolderName name: String) -> ExtraType? {
        ExtraType.folderNames[name.lowercased().trimmingCharacters(in: .whitespaces)]
    }

    public struct SuffixExtra: Sendable, Hashable {
        public var type: ExtraType
        /// The filename stem the extra binds to, e.g. `Doctor Who S01E01 Rose`.
        public var ownerStem: String
    }

    /// Detects the `<episode filename>-behindthescenes.mkv` form, which binds an
    /// extra to one specific sibling item.
    public static func suffixExtra(fromFilename filename: String) -> SuffixExtra? {
        let stem = (filename as NSString).deletingPathExtension
        let lowered = stem.lowercased()
        for (suffix, type) in ExtraType.filenameSuffixes where lowered.hasSuffix(suffix) {
            let ownerStem = String(stem.dropLast(suffix.count))
            guard !ownerStem.isEmpty else { return nil }
            return SuffixExtra(type: type, ownerStem: ownerStem)
        }
        return nil
    }

    /// Extras have no NFO, so Emby derives the on-screen title from the filename.
    /// This returns exactly what would be shown.
    public static func extraTitle(for url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
    }
}
