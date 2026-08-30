import Foundation

/// The files beside a folder's media, listed once so a season of twenty episodes
/// does not re-read the same directory twenty times.
public struct FolderListing: Sendable, Hashable {
    public var folder: URL
    /// Every non-directory entry directly inside the folder.
    public var files: [URL]
    /// Contents of the asset sub-folders that exist, keyed by lower-cased name.
    public var assetFolders: [String: [URL]]

    public init(folder: URL, files: [URL] = [], assetFolders: [String: [URL]] = [:]) {
        self.folder = folder
        self.files = files
        self.assetFolders = assetFolders
    }

    public func assetFolder(_ name: String) -> [URL] {
        assetFolders[name] ?? []
    }

    public static func read(_ folder: URL) -> FolderListing {
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return FolderListing(folder: folder)
        }

        var files: [URL] = []
        var assetFolders: [String: [URL]] = [:]

        for entry in entries {
            let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            guard isDirectory else {
                files.append(entry)
                continue
            }
            // Only the asset sub-folders are descended into; everything else in a
            // series or season folder is the scanner's business, not ours.
            let name = entry.lastPathComponent.lowercased()
            guard AssetScanner.assetFolderNames.contains(name) else { continue }
            let inner = (try? manager.contentsOfDirectory(
                at: entry,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []
            assetFolders[name] = AssetScanner.sorted(inner)
        }

        return FolderListing(folder: folder, files: AssetScanner.sorted(files), assetFolders: assetFolders)
    }
}

/// What one folder yielded.
public struct FolderAssets: Sendable, Hashable {
    /// Assets belonging to the item whose folder this is.
    public var own: [MediaAsset]
    /// Season images filed up in the *series* folder — `season01-poster.jpg` and
    /// friends. They are found here but belong to a season, so the scanner has to
    /// hand them down once it knows which seasons exist.
    public var seasonScoped: [SeasonScopedAsset]

    public init(own: [MediaAsset] = [], seasonScoped: [SeasonScopedAsset] = []) {
        self.own = own
        self.seasonScoped = seasonScoped
    }
}

public struct SeasonScopedAsset: Sendable, Hashable {
    public var season: Int
    public var asset: MediaAsset

    public init(season: Int, asset: MediaAsset) {
        self.season = season
        self.asset = asset
    }
}

/// Recognises the files that are neither video nor NFO — the images, theme media
/// and external subtitles that decide what an item can actually show.
///
/// Every rule here comes from Emby's own naming documentation, and the rule that
/// matched is recorded on each asset rather than discarded, because the interesting
/// failure is not "no poster" but "a poster Emby will never look at": the
/// documented filenames for a single-valued image are a precedence list, so
/// `poster.jpg` beside `folder.jpg` is a file doing nothing.
public enum AssetScanner: Sendable {
    public static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "tbn"]
    /// `sub` and `idx` are one track split across two files; the rest stand alone.
    public static let subtitleExtensions: Set<String> = ["ass", "srt", "ssa", "sub", "idx", "vtt"]
    public static let audioExtensions: Set<String> = [
        "mp3", "m4a", "flac", "wma", "ogg", "oga", "wav", "aac", "opus", "ape", "aif", "aiff",
    ]

    /// Sub-folders that hold assets rather than content. The scanner has to know
    /// these by name so it does not mistake `backdrops/loop.mkv` for a stray video
    /// and file it in the unassigned bin.
    public static let assetFolderNames: Set<String> = ["extrafanart", "theme-music", "backdrops", "metadata"]

    // MARK: - Folder assets

    public static func folderAssets(level: ItemLevel, listing: FolderListing) -> FolderAssets {
        var candidates: [Candidate] = []
        var seasonScoped: [Candidate] = []
        var seasonNumbers: [Int] = []

        for file in listing.files {
            let ext = file.pathExtension.lowercased()
            let stem = file.deletingPathExtension().lastPathComponent.lowercased()

            if imageExtensions.contains(ext) {
                if level == .series, let scoped = seasonScopedImage(stem: stem, file: file) {
                    seasonNumbers.append(scoped.season)
                    seasonScoped.append(scoped.candidate)
                    continue
                }
                if let candidate = folderImage(stem: stem, file: file, level: level) {
                    candidates.append(candidate)
                }
                continue
            }

            // `theme.mp3` beside the media, the first of the two documented forms.
            if stem == "theme" && audioExtensions.contains(ext) {
                candidates.append(
                    Candidate(order: 0, asset: asset(file, .themeSong, rule: "theme.ext"))
                )
            }
        }

        // `extrafanart/fanart1.jpg` — an additional backdrop, filed in a folder
        // rather than numbered in place.
        for file in listing.assetFolder("extrafanart") where imageExtensions.contains(file.pathExtension.lowercased()) {
            candidates.append(
                Candidate(
                    order: imageRules.count,
                    asset: asset(file, .backdrop, rule: "extrafanart/fanartX.ext", locationNote: "in extrafanart/")
                )
            )
        }

        for file in listing.assetFolder("theme-music") where audioExtensions.contains(file.pathExtension.lowercased()) {
            candidates.append(
                Candidate(order: 1, asset: asset(file, .themeSong, rule: "theme-music/", locationNote: "in theme-music/"))
            )
        }

        for file in listing.assetFolder("backdrops") where FilenameParser.isVideo(file) {
            candidates.append(
                Candidate(order: 0, asset: asset(file, .themeVideo, rule: "backdrops/", locationNote: "in backdrops/"))
            )
        }

        return FolderAssets(
            own: resolve(candidates),
            seasonScoped: resolve(seasonScoped, groupingBy: seasonNumbers)
                .map { SeasonScopedAsset(season: $0.group, asset: $0.asset) }
        )
    }

    // MARK: - File assets

    /// The assets bound to one media file: its thumb and its external subtitles.
    public static func fileAssets(for media: URL, listing: FolderListing) -> [MediaAsset] {
        let stem = media.deletingPathExtension().lastPathComponent
        let lowered = stem.lowercased()
        var candidates: [Candidate] = []

        for file in listing.files where imageExtensions.contains(file.pathExtension.lowercased()) {
            let fileStem = file.deletingPathExtension().lastPathComponent.lowercased()
            if fileStem == lowered + "-thumb" {
                candidates.append(Candidate(order: 0, asset: asset(file, .thumb, rule: "{name}-thumb.ext")))
            }
        }

        // The second documented form, which loses the precedence contest whenever
        // a `-thumb` file sits beside the episode.
        for file in listing.assetFolder("metadata") where imageExtensions.contains(file.pathExtension.lowercased()) {
            if file.deletingPathExtension().lastPathComponent.lowercased() == lowered {
                candidates.append(
                    Candidate(order: 1, asset: asset(file, .thumb, rule: "metadata/{name}.ext", locationNote: "in metadata/"))
                )
            }
        }

        candidates += subtitleCandidates(stem: stem, in: listing.files)
        return resolve(candidates)
    }

    // MARK: - Images

    private struct ImageRule {
        enum Numbering {
            case none
            /// `backdrop1.jpg`
            case appended
            /// `fanart-1.jpg`
            case dashed
        }

        var base: String
        var capability: Capability
        var numbering: Numbering = .none
        /// `show.jpg` names the series and means nothing in a season folder.
        var seriesFolderOnly: Bool = false
    }

    /// Emby's table, in the order it documents — which is the order the names are
    /// checked in, and therefore the precedence order within each capability.
    private static let imageRules: [ImageRule] = [
        ImageRule(base: "folder", capability: .poster),
        ImageRule(base: "poster", capability: .poster),
        ImageRule(base: "cover", capability: .poster),
        ImageRule(base: "default", capability: .poster),
        ImageRule(base: "show", capability: .poster, seriesFolderOnly: true),

        ImageRule(base: "clearart", capability: .clearArt),

        ImageRule(base: "backdrop", capability: .backdrop, numbering: .appended),
        ImageRule(base: "fanart", capability: .backdrop, numbering: .dashed),
        ImageRule(base: "background", capability: .backdrop, numbering: .dashed),
        ImageRule(base: "art", capability: .backdrop, numbering: .dashed),

        ImageRule(base: "banner", capability: .banner),

        ImageRule(base: "disc", capability: .disc),
        ImageRule(base: "cdart", capability: .disc),

        ImageRule(base: "clearlogo", capability: .logo),
        ImageRule(base: "logo", capability: .logo),

        ImageRule(base: "thumb", capability: .thumb),
        ImageRule(base: "landscape", capability: .thumb),
    ]

    private static func folderImage(stem: String, file: URL, level: ItemLevel) -> Candidate? {
        for (order, rule) in imageRules.enumerated() {
            if rule.seriesFolderOnly && level != .series { continue }
            guard let numbered = match(stem: stem, rule: rule) else { continue }
            let name = numbered ? "\(rule.base)X.ext" : "\(rule.base).ext"
            return Candidate(order: order, asset: asset(file, rule.capability, rule: name))
        }
        return nil
    }

    /// Returns whether the match used the numbered form, or `nil` for no match.
    private static func match(stem: String, rule: ImageRule) -> Bool? {
        if stem == rule.base { return false }
        let separator: String? = switch rule.numbering {
        case .none: nil
        case .appended: ""
        case .dashed: "-"
        }
        guard let separator else { return nil }
        let prefix = rule.base + separator
        guard stem.hasPrefix(prefix) else { return nil }
        let rest = stem.dropFirst(prefix.count)
        guard !rest.isEmpty, rest.allSatisfy(\.isNumber) else { return nil }
        return true
    }

    /// `season01-poster.jpg` and `season-specials-fanart.jpg`: an image for a
    /// season, kept in the series folder because the season has no folder of its
    /// own — or simply because Emby's own downloader puts it there.
    private static let seasonImageSuffixes: [(suffix: String, capability: Capability)] = [
        ("poster", .poster),
        ("fanart", .backdrop),
        ("banner", .banner),
        ("landscape", .thumb),
    ]

    private static func seasonScopedImage(stem: String, file: URL) -> (season: Int, candidate: Candidate)? {
        for (order, entry) in seasonImageSuffixes.enumerated() {
            if stem == "season-specials-\(entry.suffix)" {
                return (
                    0,
                    Candidate(
                        order: order,
                        asset: asset(
                            file,
                            entry.capability,
                            rule: "season-specials-\(entry.suffix).ext",
                            locationNote: "in the series folder"
                        )
                    )
                )
            }
            guard stem.hasSuffix("-\(entry.suffix)"), stem.hasPrefix("season") else { continue }
            let digits = stem.dropFirst("season".count).dropLast(entry.suffix.count + 1)
            guard !digits.isEmpty, digits.allSatisfy(\.isNumber), let number = Int(digits) else { continue }
            return (
                number,
                Candidate(
                    order: order,
                    asset: asset(
                        file,
                        entry.capability,
                        rule: "seasonXX-\(entry.suffix).ext",
                        locationNote: "in the series folder"
                    )
                )
            )
        }
        return nil
    }

    // MARK: - Subtitles

    /// Tokens that describe the track rather than name its language.
    private static let subtitleFlags: Set<String> = ["default", "forced", "foreign", "sdh"]

    private static func subtitleCandidates(stem: String, in files: [URL]) -> [Candidate] {
        let lowered = stem.lowercased()

        // Grouped by the whole stem, tokens included, so `Show.spa.srt` and
        // `Show.eng.srt` stay two tracks while `Show.spa.sub` and `Show.spa.idx`
        // become one.
        var order: [String] = []
        var groups: [String: [URL]] = [:]

        for file in files {
            guard subtitleExtensions.contains(file.pathExtension.lowercased()) else { continue }
            let fileStem = file.deletingPathExtension().lastPathComponent
            let loweredStem = fileStem.lowercased()
            // The dot matters: it is what keeps `Show S01E01-behindthescenes.srt`
            // from being read as a subtitle for `Show S01E01`.
            guard loweredStem == lowered || loweredStem.hasPrefix(lowered + ".") else { continue }
            if groups[loweredStem] == nil { order.append(loweredStem) }
            groups[loweredStem, default: []].append(file)
        }

        var candidates: [Candidate] = []

        for key in order {
            let group = groups[key] ?? []
            let tokens = String(key.dropFirst(lowered.count))
                .split(separator: ".")
                .map(String.init)

            var detail = SubtitleDetail(format: "")
            var languageParts: [String] = []
            for token in tokens {
                let lowered = token.lowercased()
                switch lowered {
                case "default": detail.isDefault = true
                case "forced", "foreign": detail.isForced = true
                case "sdh": detail.isHearingImpaired = true
                default: languageParts.append(token)
                }
            }
            detail.language = languageParts.isEmpty ? nil : languageParts.joined(separator: ".")

            let extensions = Set(group.map { $0.pathExtension.lowercased() })
            let suffix = tokens.isEmpty ? "" : "." + tokens.joined(separator: ".")

            if extensions.contains("sub"), extensions.contains("idx") {
                var paired = detail
                paired.format = "sub/idx"
                let file = group.first { $0.pathExtension.lowercased() == "sub" } ?? group[0]
                candidates.append(
                    Candidate(order: 0, asset: asset(file, .subtitles, rule: "{name}\(suffix).sub/idx", subtitle: paired))
                )
            }

            for file in group {
                let ext = file.pathExtension.lowercased()
                if ext == "sub" || ext == "idx", extensions.contains("sub"), extensions.contains("idx") { continue }
                var single = detail
                single.format = ext
                candidates.append(
                    Candidate(order: 0, asset: asset(file, .subtitles, rule: "{name}\(suffix).\(ext)", subtitle: single))
                )
            }
        }

        return candidates
    }

    // MARK: - What each capability accepts

    /// Every filename Emby would accept for a capability, in the order it checks
    /// them.
    ///
    /// This is what makes a *missing* capability actionable: the answer to "there
    /// is no poster" is a list of the names one could be given.
    public static func acceptedRules(for capability: Capability, at level: ItemLevel) -> [String] {
        switch capability {
        case .details:
            switch level {
            case .series: ["tvshow.nfo"]
            case .season: ["season.nfo"]
            case .episode: ["{name}.nfo"]
            }

        case .themeSong:
            ["theme.ext", "theme-music/"]

        case .themeVideo:
            ["backdrops/"]

        case .subtitles:
            [
                "{name}.ext",
                "{name}.<language>.ext",
                "{name}.<language>.forced|foreign|default|sdh.ext",
                "formats: " + subtitleExtensions.sorted().joined(separator: ", "),
            ]

        case .thumb where level == .episode:
            ["{name}-thumb.ext", "metadata/{name}.ext"]

        default:
            imageRules
                .filter { $0.capability == capability && !($0.seriesFolderOnly && level != .series) }
                .flatMap { rule -> [String] in
                    switch rule.numbering {
                    case .none: ["\(rule.base).ext"]
                    case .appended, .dashed: ["\(rule.base).ext", "\(rule.base)X.ext"]
                    }
                }
                + (capability == .backdrop ? ["extrafanart/fanartX.ext"] : [])
                + seasonScopedRules(for: capability, at: level)
        }
    }

    /// A season's images can be filed up in the series folder under a name that
    /// carries the season number, so those names belong in a season's list too.
    private static func seasonScopedRules(for capability: Capability, at level: ItemLevel) -> [String] {
        guard level == .season,
              let entry = seasonImageSuffixes.first(where: { $0.capability == capability })
        else { return [] }
        return [
            "seasonXX-\(entry.suffix).ext (in the series folder)",
            "season-specials-\(entry.suffix).ext (in the series folder)",
        ]
    }

    // MARK: - Assembly

    /// A matched file plus where its rule sits in the documented precedence order.
    private struct Candidate {
        var order: Int
        var asset: MediaAsset
    }

    /// Orders the matches the way they are presented and marks the ones Emby will
    /// never reach.
    private static func resolve(_ candidates: [Candidate]) -> [MediaAsset] {
        resolve(candidates, groupingBy: Array(repeating: 0, count: candidates.count)).map(\.asset)
    }

    /// - Parameter groups: a discriminator per candidate, so season images kept in
    ///   the series folder shadow each other per season rather than across all of
    ///   them. Same length as `candidates`.
    private static func resolve(
        _ candidates: [Candidate],
        groupingBy groups: [Int]
    ) -> [(group: Int, asset: MediaAsset)] {
        let capabilityOrder = Dictionary(
            uniqueKeysWithValues: Capability.allCases.enumerated().map { ($0.element, $0.offset) }
        )

        let sorted = zip(groups, candidates).sorted { lhs, rhs in
            if lhs.0 != rhs.0 { return lhs.0 < rhs.0 }
            let left = capabilityOrder[lhs.1.asset.capability] ?? 0
            let right = capabilityOrder[rhs.1.asset.capability] ?? 0
            if left != right { return left < right }
            if lhs.1.order != rhs.1.order { return lhs.1.order < rhs.1.order }
            return lhs.1.asset.name.localizedStandardCompare(rhs.1.asset.name) == .orderedAscending
        }

        var seen: Set<String> = []
        return sorted.map { group, candidate in
            var asset = candidate.asset
            guard !asset.capability.isMultiValued else { return (group, asset) }
            let key = "\(group)/\(asset.capability.rawValue)"
            if seen.contains(key) { asset.isShadowed = true } else { seen.insert(key) }
            return (group, asset)
        }
    }

    private static func asset(
        _ file: URL,
        _ capability: Capability,
        rule: String,
        locationNote: String? = nil,
        subtitle: SubtitleDetail? = nil
    ) -> MediaAsset {
        MediaAsset(
            file: file,
            capability: capability,
            rule: rule,
            locationNote: locationNote,
            subtitle: subtitle,
            byteCount: byteCount(of: file)
        )
    }

    static func byteCount(of url: URL) -> Int? {
        (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
    }

    static func sorted(_ urls: [URL]) -> [URL] {
        urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
}
