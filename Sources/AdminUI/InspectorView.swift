import HomeTheatreCore
import SwiftUI

/// What the drawer is describing. Resolved from the most specific selection, so
/// picking a season steps back out of an episode.
enum InspectorTarget: Equatable {
    case series(ResolvedSeries)
    case season(series: ResolvedSeries, season: ResolvedSeason, scanned: Season?)
    case episode(ResolvedEpisode)

    var title: String {
        switch self {
        case .series(let resolved): resolved.series.name
        case .season(_, let season, _): season.number == 0 ? "Specials" : "Season \(season.number)"
        case .episode(let resolved): resolved.episode.title ?? resolved.episode.file.lastPathComponent
        }
    }

    var kind: String {
        switch self {
        case .series: "Series"
        case .season: "Season"
        case .episode: "Episode"
        }
    }

    var nfoURL: URL? {
        switch self {
        case .series(let resolved): resolved.series.nfoURL
        case .season(_, _, let scanned): scanned?.nfoURL
        case .episode(let resolved): resolved.episode.nfoURL
        }
    }

    /// The file the item is about, which is worth showing when there is no NFO.
    var mediaPath: URL {
        switch self {
        case .series(let resolved): resolved.series.folder
        case .season(_, _, let scanned): scanned?.folder ?? URL(fileURLWithPath: "/")
        case .episode(let resolved): resolved.episode.file
        }
    }
}

struct InspectorView: View {
    let target: InspectorTarget?
    let inspection: NFOInspection?
    let loadError: String?

    var body: some View {
        Group {
            if let target {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        header(target)
                        Divider()
                        resolvedSection(target)
                        Divider()
                        nfoSection(target)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                ContentUnavailableView("Nothing selected", systemImage: "sidebar.right")
            }
        }
        .inspectorColumnWidth(min: 320, ideal: 420, max: 640)
    }

    // MARK: - Header

    private func header(_ target: InspectorTarget) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(target.kind.uppercased())
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(target.title)
                .font(.headline)
            Text(target.mediaPath.path)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
    }

    // MARK: - Resolved state

    @ViewBuilder
    private func resolvedSection(_ target: InspectorTarget) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Resolved").font(.subheadline).bold()

            resolvedRows(target)
        }
    }

    @ViewBuilder
    private func resolvedRows(_ target: InspectorTarget) -> some View {
        Group {
            switch target {
            case .series(let resolved):
                pair("Display order", resolved.series.displayOrder?.rawValue ?? "aired (default)")
                pair("Seasons", "\(resolved.seasons.count)")
                pair("Episodes", "\(resolved.episodeCount)")
                pair("Extras", "\(resolved.series.extras.count)")
                if !resolved.series.unassigned.isEmpty {
                    pair("Unassigned", "\(resolved.series.unassigned.count)")
                }
                providerIDs(resolved.series.providerIds)

            case .season(_, let season, let scanned):
                pair("Episodes", "\(season.episodes.count)")
                if let scanned {
                    if let title = scanned.title { pair("Title", title) }
                    // The number can come from either the folder or the NFO, and
                    // which one won is the interesting part.
                    if scanned.numberOverriddenByNFO, let folderNumber = scanned.folderNumber {
                        pair("Number", "\(scanned.number) — folder says \(folderNumber)", tone: .orange)
                    } else {
                        pair("Number", "\(scanned.number)")
                    }
                    pair("Extras", "\(scanned.extras.count)")
                    if scanned.locked { pair("Locked", "yes") }
                    providerIDs(scanned.providerIds)
                }

            case .episode(let resolved):
                let episode = resolved.episode
                // Identity and display are the whole point, so they are shown as
                // two separate facts rather than one merged position.
                pair("Identity", episode.identityLabel)
                pair(
                    "Display",
                    resolved.source == .pinned
                        ? "\(episode.displaySeason.map(String.init) ?? "–")×\(episode.displayNumber.map(String.init) ?? "–") (pinned)"
                        : "inherited",
                    tone: resolved.source == .pinned ? .accentColor : nil
                )
                pair("Renders at", "season \(resolved.effectiveSeason), position \(resolved.effectiveNumber)")
                if resolved.isRelocated {
                    pair("Relocated", "from season \(episode.season ?? 0)", tone: .orange)
                }
                if episode.locked { pair("Locked", "yes") }
                if !episode.extras.isEmpty { pair("Extras", "\(episode.extras.count)") }
                providerIDs(episode.providerIds)
            }
        }
    }

    @ViewBuilder
    private func providerIDs(_ ids: [String: String]) -> some View {
        ForEach(ids.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
            pair(key, value)
        }
    }

    /// Label at a bounded width, value taking the rest.
    ///
    /// `maxWidth: .infinity` is what makes the value wrap to the space actually
    /// available; `fixedSize` would ask for its full unwrapped width instead and
    /// push the text past the edge of the drawer.
    private func pair(_ label: String, _ value: String, tone: Color? = nil) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 96, alignment: .topLeading)
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(tone ?? .primary)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .textSelection(.enabled)
        }
    }

    // MARK: - NFO

    @ViewBuilder
    private func nfoSection(_ target: InspectorTarget) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("NFO").font(.subheadline).bold()
                Spacer()
                if let url = target.nfoURL {
                    Text(url.lastPathComponent)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            if let loadError {
                Label(loadError, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if target.nfoURL == nil {
                Label(
                    "No NFO on disk — everything above was derived from the filename and folder layout.",
                    systemImage: "doc.badge.ellipsis"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            } else if let inspection {
                fieldList(inspection)
                DisclosureGroup("Source") {
                    Text(inspection.rawText)
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6)
                        .background(Color(nsColor: .textBackgroundColor), in: .rect(cornerRadius: 5))
                }
                .font(.caption)
            } else {
                ProgressView().controlSize(.small)
            }
        }
    }

    private func fieldList(_ inspection: NFOInspection) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(inspection.fields.enumerated()), id: \.offset) { _, field in
                NFOFieldRow(field: field)
            }
        }
    }
}

private struct NFOFieldRow: View {
    let field: NFOField

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            // A bounded width, so a long tag name wraps within its column instead
            // of widening the row.
            Text(String(repeating: "  ", count: field.depth) + field.name)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(nameColor)
                .frame(width: 118, alignment: .topLeading)

            VStack(alignment: .leading, spacing: 1) {
                Text(field.value)
                    .font(.system(.caption2, design: .monospaced))
                    .strikethrough(field.isIgnored)
                    .foregroundStyle(field.isIgnored ? .secondary : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)

                // Under the value rather than beside it: a third column would take
                // width from the thing being explained.
                if let note {
                    Text(note)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
        }
    }

    private var nameColor: Color {
        switch field.role {
        case .identity: .blue
        case .ordering: .purple
        case .lock: .green
        case .other: .secondary
        }
    }

    /// The two rules that are invisible in the file itself.
    private var note: String? {
        switch field.status {
        case .superseded: "overwritten below"
        case .discardedNonPositive: "ignored, must be > 0"
        case .normal, .effective: nil
        }
    }
}
