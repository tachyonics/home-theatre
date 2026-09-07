// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the home-silo project authors

import HomeTheatreCore
import SwiftUI

/// Which browsing column the user is working in.
///
/// Tracked as focus rather than derived from the selections, because a click can
/// change the column being worked in without changing any selection — see
/// ``ContentView/focus``.
enum ColumnFocus: Hashable {
    case series, season, episode
}

// MARK: - Series

struct SeriesColumn: View {
    let series: [ResolvedSeries]
    @Binding var selection: URL?
    @FocusState.Binding var focusedColumn: ColumnFocus?

    var body: some View {
        List(selection: $selection) {
            ForEach(series, id: \.series.folder) { resolved in
                SeriesRow(resolved: resolved).tag(resolved.series.folder)
            }
        }
        .focused($focusedColumn, equals: .series)
        .navigationTitle("Series")
    }
}

private struct SeriesRow: View {
    let resolved: ResolvedSeries

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(resolved.series.name)
                .lineLimit(3)
                // Wrap to the column width rather than truncating a long title.
                .fixedSize(horizontal: false, vertical: true)

            Text("\(resolved.seasons.count) seasons · \(resolved.episodeCount) episodes")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 4) {
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
    }
}

// MARK: - Seasons

/// What the season column has selected.
///
/// A season and one of the series' extras are different kinds of thing sharing one
/// list, so the selection has to say which it is: `List` carries a single selection
/// type, and rows tagged with a second one are silently unselectable.
enum SeasonSelection: Hashable {
    case season(Int)
    case extra(URL)
}

struct SeasonColumn: View {
    let series: ResolvedSeries?
    /// Queued filings by the file each will produce, so an extra that is only
    /// queued can be told from one already on disk.
    let pending: [URL: PendingFiling]
    @Binding var selection: SeasonSelection?
    @FocusState.Binding var focusedColumn: ColumnFocus?
    /// Queues the moves that make a dragged episode an extra of *this series*,
    /// returning false when the id names nothing — the column knows the
    /// destination, but only the content view holds the scan the id resolves
    /// against.
    let fileAsSeriesExtra: (UUID, ExtrasFolder) -> Bool

    /// Highlighted while a drag is over it, so a type holding nothing still reads
    /// as somewhere a file can be dropped.
    @State private var dropTarget: ExtraType?

    @State private var extrasExpanded = true

    /// Which type groups are shut, rather than which are open: everything starts
    /// open, so the default needs no entry, and a type that only appears once
    /// something is filed as it cannot arrive already hidden.
    @State private var collapsedTypes: Set<ExtraType> = []

    var body: some View {
        Group {
            if let series {
                List(selection: $selection) {
                    Section("Seasons") {
                        ForEach(series.seasons, id: \.number) { season in
                            SeasonRow(season: season, scanned: scanned(season.number, in: series))
                                .tag(SeasonSelection.season(season.number))
                        }
                    }

                    // Extras and unplaced files belong to the series rather than to
                    // any season, so they live here instead of in the episode pane.
                    seriesExtras(of: series)

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
                .focused($focusedColumn, equals: .season)
            } else {
                ContentUnavailableView("No series selected", systemImage: "sidebar.left")
            }
        }
        .navigationTitle(series?.series.name ?? "Seasons")
    }

    private func scanned(_ number: Int, in series: ResolvedSeries) -> Season? {
        series.series.seasons.first { $0.number == number }
    }

    // MARK: - Series extras

    /// The series' own extras, under a heading per type they can be filed as.
    ///
    /// Every filable type gets a heading whether or not it holds anything, the same
    /// way the extras pane keeps every folder Emby recognises: the heading is also
    /// where an episode is dropped to make it that kind of extra, and hiding the
    /// empty ones would leave no way to file the first one.
    ///
    /// Only the series' *own* extras are here — nothing gathered from the seasons
    /// or episodes below it — because saying whose extras these are is the whole
    /// point of listing them against the series.
    @ViewBuilder
    private func seriesExtras(of series: ResolvedSeries) -> some View {
        // Two levels of collapse, because there are two things worth getting out
        // of the way: the whole list, when you are working on seasons, and one
        // kind of extra, when the series has thirty trailers and you are not
        // looking at trailers. Both leave their heading, so what has been folded
        // away still says what it is and how much of it there is.
        // The heading is a control of our own rather than `Section(isExpanded:)`:
        // that draws no disclosure control at all in this list's style, leaving a
        // section that collapses only if you know it does. Built here, both levels
        // fold the same way and look it.
        Section {
            if extrasExpanded {
                extraTypeGroups(of: series)
            }
        } header: {
            SeriesExtrasHeading(
                count: series.series.extras.count,
                isCollapsed: !extrasExpanded,
                toggle: { withAnimation(.snappy(duration: 0.15)) { extrasExpanded.toggle() } }
            )
        }
    }

    @ViewBuilder
    private func extraTypeGroups(of series: ResolvedSeries) -> some View {
        ForEach(types(in: series), id: \.self) { type in
                let extras = extras(of: type, in: series)

                ExtraTypeHeading(
                    type: type,
                    count: extras.count,
                    isCollapsed: collapsedTypes.contains(type),
                    // Nothing to hide, so no control that pretends otherwise. The
                    // heading is still a destination — that is what an empty group
                    // is for.
                    isCollapsible: !extras.isEmpty,
                    toggle: { toggle(type) }
                )
                .listRowBackground(highlight(type))
                // A heading names a group, so it cannot also be a thing to
                // select — clicking it would leave the details drawer
                // describing nothing.
                .selectionDisabled()
                .help(helpText(for: type))
                .dropDestination(for: String.self) { items, _ in
                    drop(items, as: type)
                } isTargeted: { over in
                    dropTarget = over ? type : nil
                }

                if !collapsedTypes.contains(type) {
                    ForEach(extras, id: \.file) { extra in
                        extraRow(extra)
                            .tag(SeasonSelection.extra(extra.file))
                            .listRowBackground(highlight(type))
                            // The rows take a drop too: the group is one target,
                            // and aiming at the heading of a long list would mean
                            // scrolling back to it.
                            .dropDestination(for: String.self) { items, _ in
                                drop(items, as: type)
                            } isTargeted: { over in
                                dropTarget = over ? type : nil
                            }
                    }
                }
        }
    }

    private func toggle(_ type: ExtraType) {
        withAnimation(.snappy(duration: 0.15)) {
            if collapsedTypes.remove(type) == nil { collapsedTypes.insert(type) }
        }
    }

    /// An extra that is only queued stays draggable, because the decision that put
    /// it here is still a decision — it can be moved to another type, or dropped
    /// back on the season to be an episode again. What is dragged is the episode
    /// id, exactly as when it left the season: the queue is superseded rather than
    /// added to, so the second drop describes the same move from the same start.
    ///
    /// An extra already on disk carries no such id and stays put. Moving one is a
    /// different change — nothing about it says which episode, if any, it once was.
    @ViewBuilder
    private func extraRow(_ extra: Extra) -> some View {
        let row = ExtraRow(extra: extra, filing: pending[extra.file], showsType: false)
            .padding(.leading, 14)

        if let filing = pending[extra.file] {
            row.draggable(filing.episode.id.uuidString)
        } else {
            row
        }
    }

    /// Every type that can be filed, plus any that is present without being one —
    /// a list claiming to show the series' extras must not quietly leave one out
    /// because there is nowhere to drop a new one of its kind.
    private func types(in series: ResolvedSeries) -> [ExtraType] {
        var types = ExtraType.filable
        for extra in series.series.extras where !types.contains(extra.type) {
            types.append(extra.type)
        }
        return types
    }

    /// Grouped by type rather than by folder: `extras/` and `specials/` both hold
    /// ``ExtraType/unknown`` extras, and to a client they are the same kind of
    /// thing however they were filed.
    private func extras(of type: ExtraType, in series: ResolvedSeries) -> [Extra] {
        series.series.extras.filter { $0.type == type }
    }

    private func drop(_ items: [String], as type: ExtraType) -> Bool {
        guard let folder = type.canonicalFolder else { return false }
        // The payload is an entity id. Anything else dragged in from outside
        // simply resolves to nothing and is refused, which is why no custom
        // UTType is needed.
        let filed = items.compactMap(UUID.init(uuidString:))
            .reduce(false) { fileAsSeriesExtra($1, folder) || $0 }

        // A group that was shut opens to show what just landed in it. Filing
        // something and watching the count tick up while the thing itself stays
        // hidden is the one moment the fold is in the way.
        if filed { collapsedTypes.remove(type) }
        return filed
    }

    /// The whole group lights up, heading and rows together, since dropping on any
    /// of them does the same thing.
    private func highlight(_ type: ExtraType) -> Color {
        dropTarget == type ? Color.accentColor.opacity(0.25) : Color.clear
    }

    private func helpText(for type: ExtraType) -> String {
        guard let folder = type.canonicalFolder else {
            return "Extras of this kind are bound by a filename suffix, so nothing can be filed here."
        }
        return "Drop an episode here to move it into the series' “\(folder.name)” folder, which makes it a \(type.displayName) extra."
    }
}

/// Names the whole list and how many extras are in it, and folds it away. Reads as
/// a section header because it is one — the control is what the style would not
/// give us.
private struct SeriesExtrasHeading: View {
    let count: Int
    let isCollapsed: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                    .frame(width: 9)
                Text("Series extras")
                Spacer()
                Text("\(count)")
                    .monospacedDigit()
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

/// Names one group of extras and how many are in it — and is both the drop target
/// for making another one and the control that folds the group away.
private struct ExtraTypeHeading: View {
    let type: ExtraType
    let count: Int
    let isCollapsed: Bool
    let isCollapsible: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) { label }
            .buttonStyle(.plain)
            .disabled(!isCollapsible)
    }

    private var label: some View {
        HStack(spacing: 6) {
            // Held open even when there is nothing to disclose, so the headings
            // line up as one column rather than stepping in and out.
            Image(systemName: "chevron.right")
                .font(.caption2)
                .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                .opacity(isCollapsible ? 1 : 0)
                .frame(width: 9)

            Text(type.displayName.uppercased())
                .font(.caption2)
                .fontWeight(.semibold)
            Spacer()
            Text("\(count)")
                .font(.caption2)
                .monospacedDigit()
        }
        // Dimmed to a third level when empty: the heading is still a destination,
        // but it should not read as loudly as one holding something.
        .foregroundStyle(count == 0 ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
        .padding(.top, 2)
        // The row is the target, not just the text sitting in it.
        .contentShape(.rect)
    }
}

private struct SeasonRow: View {
    let season: ResolvedSeason
    let scanned: Season?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(season.number == 0 ? "Specials" : "Season \(season.number)")

            Text("\(season.episodes.count) episodes")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 4) {
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
    }
}

// MARK: - Episodes

struct EpisodeColumn: View {
    let series: ResolvedSeries?
    let season: ResolvedSeason?
    /// Queued filings by the file each will produce. An episode with one queued has
    /// already left this list — it is drawn under Season extras instead, which is
    /// where applying will actually put it — so this is only ever read to badge the
    /// extra it became.
    let pending: [URL: PendingFiling]
    @Binding var selection: URL?
    @FocusState.Binding var focusedColumn: ColumnFocus?
    /// Cancels the queued filing that took an episode out of this season, putting
    /// it back among the episodes. Returns false when the id names nothing queued,
    /// or something queued out of a different season.
    let restoreToSeason: (UUID) -> Bool

    /// Highlighted while a drag is over the list, since the target here is the
    /// season as a whole rather than any one row in it.
    @State private var isDropTargeted = false

    var body: some View {
        Group {
            if let season {
                List(selection: $selection) {
                    Section("Display order") {
                        ForEach(season.episodes, id: \.episode.file) { resolved in
                            EpisodeRow(resolved: resolved, pending: pending)
                                .tag(resolved.episode.file)
                                // The entity id, not the path: where the file sits
                                // is exactly what a drop is about to change.
                                .draggable(resolved.episode.id.uuidString)
                        }
                    }

                    if let extras = seasonExtras, !extras.isEmpty {
                        Section("Season extras") {
                            ForEach(extras, id: \.file) { extra in
                                ExtraRow(extra: extra, filing: pending[extra.file])
                            }
                        }
                    }
                }
                .listStyle(.inset)
                .focused($focusedColumn, equals: .episode)
                // The whole list, not a row: dropping here says "this belongs in
                // the season", which is about the season and not about whichever
                // episode the cursor happened to be over.
                .dropDestination(for: String.self) { items, _ in
                    items.compactMap(UUID.init(uuidString:))
                        .reduce(false) { restoreToSeason($1) || $0 }
                } isTargeted: { over in
                    isDropTargeted = over
                }
                .overlay {
                    if isDropTargeted {
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color.accentColor, lineWidth: 2)
                            .padding(2)
                            // The border reports the target; the drop is the
                            // list's, and must not be caught on the way in.
                            .allowsHitTesting(false)
                    }
                }
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
    /// Passed down for the episode's own extras; the episode itself is never
    /// pending, since a filed one is no longer drawn as an episode at all.
    let pending: [URL: PendingFiling]

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
                    // minWidth, not width: S05E12-E13 is wider than S01E01.
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(minWidth: 90, alignment: .leading)

                Text(resolved.episode.title ?? resolved.episode.file.lastPathComponent)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 8)

                // The title gives way first; badges are short and load-bearing.
                badges.layoutPriority(1)
            }

            ForEach(resolved.episode.extras, id: \.file) { extra in
                ExtraRow(extra: extra, filing: pending[extra.file]).padding(.leading, 132)
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
    /// Set when this extra is one a queued filing will produce, rather than one
    /// that is already on disk.
    var filing: PendingFiling? = nil
    /// False where the list is already grouped by type, and repeating it on every
    /// row would say the same thing twice.
    var showsType = true

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "paperclip")
                .font(.caption2)
                .foregroundStyle(.secondary)
            if showsType {
                Text(extra.type.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            // Extras carry no NFO, so this filename is the on-screen title.
            Text(extra.title)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
            if let filing {
                Badge("Pending", tone: .pending)
                    .help("\(filing.action.title) \(filing.action.detail) — queued, not yet applied.")
            }
        }
    }
}

struct Badge: View {
    enum Tone { case neutral, info, warning, pending }

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
        case .pending: Color.purple.opacity(0.18)
        }
    }

    private var foreground: Color {
        switch tone {
        case .neutral: .secondary
        case .info: .accentColor
        case .warning: .orange
        case .pending: .purple
        }
    }
}
