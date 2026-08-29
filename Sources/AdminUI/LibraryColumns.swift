import HomeTheatreCore
import SwiftUI

// MARK: - Series

struct SeriesColumn: View {
    let series: [ResolvedSeries]
    @Binding var selection: URL?

    var body: some View {
        List(selection: $selection) {
            ForEach(series, id: \.series.folder) { resolved in
                SeriesRow(resolved: resolved).tag(resolved.series.folder)
            }
        }
        .navigationTitle("Series")
    }
}

private struct SeriesRow: View {
    let resolved: ResolvedSeries

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(resolved.series.name).lineLimit(2)

            HStack(spacing: 6) {
                Text("\(resolved.seasons.count) seasons · \(resolved.episodeCount) episodes")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                // Only worth surfacing when it is not the default, since a series
                // with no <displayorder> behaves as aired anyway.
                if let order = resolved.series.displayOrder, order != .aired {
                    Badge(order.rawValue.uppercased(), tone: .info)
                }
                if resolved.series.nfoURL == nil {
                    Badge("no nfo", tone: .warning)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Seasons

struct SeasonColumn: View {
    let series: ResolvedSeries?
    @Binding var selection: Int?

    var body: some View {
        Group {
            if let series {
                List(selection: $selection) {
                    Section("Seasons") {
                        ForEach(series.seasons, id: \.number) { season in
                            SeasonRow(season: season, scanned: scanned(season.number, in: series))
                                .tag(season.number)
                        }
                    }

                    // Extras and unplaced files belong to the series rather than to
                    // any season, so they live here instead of in the episode pane.
                    if !series.series.extras.isEmpty {
                        Section("Series extras") {
                            ForEach(series.series.extras, id: \.file) { ExtraRow(extra: $0) }
                        }
                    }

                    if !series.series.unassigned.isEmpty {
                        Section("Unassigned") {
                            ForEach(series.series.unassigned, id: \.self) { file in
                                Label(file.lastPathComponent, systemImage: "questionmark.folder")
                                    .font(.callout)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                    }
                }
            } else {
                ContentUnavailableView("No series selected", systemImage: "sidebar.left")
            }
        }
        .navigationTitle(series?.series.name ?? "Seasons")
    }

    private func scanned(_ number: Int, in series: ResolvedSeries) -> Season? {
        series.series.seasons.first { $0.number == number }
    }
}

private struct SeasonRow: View {
    let season: ResolvedSeason
    let scanned: Season?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(season.number == 0 ? "Specials" : "Season \(season.number)")

            HStack(spacing: 6) {
                Text("\(season.episodes.count) episodes")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let scanned {
                    if scanned.nfoURL == nil {
                        Badge("no nfo", tone: .warning)
                    }
                    if scanned.locked {
                        Badge("locked", tone: .neutral)
                    }
                    // A folder name disagreeing with <seasonnumber> is worth seeing
                    // rather than silently resolving.
                    if scanned.numberOverriddenByNFO, let folderNumber = scanned.folderNumber {
                        Badge("folder says \(folderNumber)", tone: .warning)
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Episodes

struct EpisodeColumn: View {
    let series: ResolvedSeries?
    let season: ResolvedSeason?
    @Binding var selection: URL?

    var body: some View {
        Group {
            if let season {
                List(selection: $selection) {
                    Section("Display order") {
                        ForEach(season.episodes, id: \.episode.file) { resolved in
                            EpisodeRow(resolved: resolved).tag(resolved.episode.file)
                        }
                    }

                    if let extras = seasonExtras, !extras.isEmpty {
                        Section("Season extras") {
                            ForEach(extras, id: \.file) { ExtraRow(extra: $0) }
                        }
                    }
                }
                .listStyle(.inset)
            } else {
                ContentUnavailableView("No season selected", systemImage: "list.bullet.indent")
            }
        }
        .navigationTitle(seasonTitle)
    }

    private var seasonTitle: String {
        guard let season else { return "Episodes" }
        return season.number == 0 ? "Specials" : "Season \(season.number)"
    }

    private var seasonExtras: [Extra]? {
        guard let season, let series else { return nil }
        return series.series.seasons.first { $0.number == season.number }?.extras
    }
}

private struct EpisodeRow: View {
    let resolved: ResolvedEpisode

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("\(resolved.effectiveNumber)")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, alignment: .trailing)

                Text(resolved.episode.identityLabel)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 90, alignment: .leading)

                Text(resolved.episode.title ?? resolved.episode.file.lastPathComponent)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 8)

                badges
            }

            ForEach(resolved.episode.extras, id: \.file) { extra in
                ExtraRow(extra: extra).padding(.leading, 128)
            }
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private var badges: some View {
        HStack(spacing: 6) {
            switch resolved.source {
            case .pinned:
                let season = resolved.episode.displaySeason.map(String.init) ?? "–"
                let number = resolved.episode.displayNumber.map(String.init) ?? "–"
                Badge("pinned \(season)×\(number)", tone: .info)
            case .inherited:
                Badge("inherited", tone: .neutral)
            }

            // Display numbering moved this out of its identity season — a special
            // interleaved into the run of ordinary seasons, typically.
            if resolved.isRelocated {
                Badge("from S\(resolved.episode.season ?? 0)", tone: .info)
            }
            if resolved.episode.locked {
                Badge("locked", tone: .neutral)
            }
            if resolved.episode.nfoURL == nil {
                Badge("no nfo", tone: .warning)
            }
        }
    }
}

// MARK: - Shared rows

private struct ExtraRow: View {
    let extra: Extra

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "paperclip")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(extra.type.displayName)
                .font(.caption)
                .foregroundStyle(.secondary)
            // Extras carry no NFO, so this filename is the on-screen title.
            Text(extra.title)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

private struct Badge: View {
    enum Tone { case neutral, info, warning }

    let text: String
    let tone: Tone

    init(_ text: String, tone: Tone = .neutral) {
        self.text = text
        self.tone = tone
    }

    var body: some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(background, in: .rect(cornerRadius: 4))
            .foregroundStyle(foreground)
    }

    private var background: Color {
        switch tone {
        case .neutral: Color.secondary.opacity(0.12)
        case .info: Color.accentColor.opacity(0.15)
        case .warning: Color.orange.opacity(0.18)
        }
    }

    private var foreground: Color {
        switch tone {
        case .neutral: .secondary
        case .info: .accentColor
        case .warning: .orange
        }
    }
}
