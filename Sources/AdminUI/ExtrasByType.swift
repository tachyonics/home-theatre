// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the home-silo project authors

import HomeTheatreCore
import SwiftUI

/// One item's own extras, under a heading per type they can be filed as.
///
/// Written once and used at two levels — the series' extras in the season column,
/// a season's in the episode column — because they are the same thing about
/// different owners, and two copies would be two sets of behaviour to keep in
/// step. What actually differs is where a drop puts the file, and that is the
/// owner's business, so it arrives as a closure.
///
/// Only the item's *own* extras belong here, never any gathered from below it.
/// Saying whose extras these are is the whole point of showing them against the
/// item rather than in the drawer, which answers the wider question.
struct ExtrasByType<Tag: Hashable>: View {
    /// `Series extras` / `Season extras`.
    let title: String
    /// How the help text names the destination: `the series`, `this season`.
    let ownerDescription: String
    let extras: [Extra]
    /// Queued filings by the file each will produce, so an extra that is only
    /// queued can be told from one already on disk.
    let pending: [URL: PendingFiling]
    /// What a row is tagged with. The two columns select different things, and a
    /// `List` carries one selection type, so the owner supplies it.
    let tag: (Extra) -> Tag
    /// Queues the moves that make a dragged episode an extra of this item,
    /// returning false when the id names nothing — the section knows the
    /// destination, but only the content view holds the scan the id resolves
    /// against.
    let fileAsExtra: (UUID, ExtrasFolder) -> Bool

    /// Highlighted while a drag is over it, so a type holding nothing still reads
    /// as somewhere a file can be dropped.
    @State private var dropTarget: ExtraType?

    @State private var isExpanded = true

    /// Which type groups are shut, rather than which are open: everything starts
    /// open, so the default needs no entry, and a type that only appears once
    /// something is filed as it cannot arrive already hidden.
    @State private var collapsedTypes: Set<ExtraType> = []

    var body: some View {
        // Two levels of collapse, because there are two things worth getting out
        // of the way: the whole list, when you are working on what is above it,
        // and one kind of extra, when the item has thirty trailers and you are not
        // looking at trailers. Both leave their heading, so what has been folded
        // away still says what it is and how much of it there is.
        //
        // The heading is a control of our own rather than `Section(isExpanded:)`:
        // that draws no disclosure control at all in this list's style, leaving a
        // section that collapses only if you already know it does.
        Section {
            if isExpanded { groups }
        } header: {
            ExtrasSectionHeading(
                title: title,
                count: extras.count,
                isCollapsed: !isExpanded,
                toggle: { withAnimation(.snappy(duration: 0.15)) { isExpanded.toggle() } }
            )
        }
    }

    /// Every filable type gets a heading whether or not it holds anything, the same
    /// way the extras pane keeps every folder Emby recognises: the heading is also
    /// where an episode is dropped to make it that kind of extra, and hiding the
    /// empty ones would leave no way to file the first one.
    @ViewBuilder
    private var groups: some View {
        ForEach(types, id: \.self) { type in
            let group = extras(of: type)

            ExtraTypeHeading(
                type: type,
                count: group.count,
                isCollapsed: collapsedTypes.contains(type),
                // Nothing to hide, so no control that pretends otherwise. The
                // heading is still a destination — that is what an empty group is
                // for.
                isCollapsible: !group.isEmpty,
                toggle: { toggle(type) }
            )
            .listRowBackground(highlight(type))
            // A heading names a group, so it cannot also be a thing to select —
            // clicking it would leave the details drawer describing nothing.
            .selectionDisabled()
            .help(helpText(for: type))
            .dropDestination(for: String.self) { items, _ in
                drop(items, as: type)
            } isTargeted: { over in
                dropTarget = over ? type : nil
            }

            if !collapsedTypes.contains(type) {
                ForEach(group, id: \.file) { extra in
                    row(extra)
                        .tag(tag(extra))
                        .listRowBackground(highlight(type))
                        // The rows take a drop too: the group is one target, and
                        // aiming at the heading of a long list would mean
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

    /// An extra that is only queued stays draggable, because the decision that put
    /// it here is still a decision — it can be moved to another type, or dropped
    /// back on the season to be an episode again. What is dragged is the episode
    /// id, exactly as when it left the season: the queue is superseded rather than
    /// added to, so the second drop describes the same move from the same start.
    ///
    /// An extra already on disk carries no such id and stays put. Moving one is a
    /// different change — nothing about it says which episode, if any, it once was.
    @ViewBuilder
    private func row(_ extra: Extra) -> some View {
        let row = ExtraRow(extra: extra, filing: pending[extra.file], showsType: false)
            .padding(.leading, 14)

        if let filing = pending[extra.file] {
            row.draggable(filing.episode.id.uuidString)
        } else {
            row
        }
    }

    // MARK: - Grouping

    /// Every type that can be filed, plus any that is present without being one —
    /// a list claiming to show an item's extras must not quietly leave one out
    /// because there is nowhere to drop a new one of its kind.
    private var types: [ExtraType] {
        var types = ExtraType.filable
        for extra in extras where !types.contains(extra.type) {
            types.append(extra.type)
        }
        return types
    }

    /// Grouped by type rather than by folder: `extras/` and `specials/` both hold
    /// ``ExtraType/unknown`` extras, and to a client they are the same kind of
    /// thing however they were filed.
    private func extras(of type: ExtraType) -> [Extra] {
        extras.filter { $0.type == type }
    }

    // MARK: - Folding and dropping

    private func toggle(_ type: ExtraType) {
        withAnimation(.snappy(duration: 0.15)) {
            if collapsedTypes.remove(type) == nil { collapsedTypes.insert(type) }
        }
    }

    private func drop(_ items: [String], as type: ExtraType) -> Bool {
        guard let folder = type.canonicalFolder else { return false }
        // The payload is an entity id. Anything else dragged in from outside
        // simply resolves to nothing and is refused, which is why no custom
        // UTType is needed.
        let filed = items.compactMap(UUID.init(uuidString:))
            .reduce(false) { fileAsExtra($1, folder) || $0 }

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
        return "Drop an episode here to move it into \(ownerDescription)' “\(folder.name)” folder, which makes it a \(type.displayName) extra."
    }
}

// MARK: - Headings

/// Names the whole list and how many extras are in it, and folds it away. Reads as
/// a section header because it is one — the control is what the style would not
/// give us.
private struct ExtrasSectionHeading: View {
    let title: String
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
                Text(title)
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

// MARK: - Rows

/// One extra, wherever it is listed: under its type here, or against the episode
/// or season it hangs off in the browsing columns.
struct ExtraRow: View {
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
