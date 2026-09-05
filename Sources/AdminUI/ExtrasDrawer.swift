import AppKit
import HomeTheatreCore
import SwiftUI

/// Two panes: the extra types present for the selected item, and the extras of the
/// chosen type. Scope follows the same target as the details drawer.
struct ExtrasDrawer: View {
    let target: InspectorTarget?
    @Binding var selection: ExtrasFilter
    /// Queues the moves that file a dragged episode into a folder, returning false
    /// when the id names nothing — the drawer knows the destination, but only the
    /// content view holds the scan the id has to be resolved against.
    let fileAsExtra: (UUID, ExtrasFolder) -> Bool

    /// Highlighted while a drag is over it, so an empty row still reads as a target.
    @State private var dropTarget: String?

    /// The left pane is a fixed list of destinations, not a summary of what is
    /// present — every recognised folder stays visible so an extra can be filed
    /// into an empty one.
    enum ExtrasFilter: Hashable {
        case all
        case folder(String)
        case filenameSuffix
    }

    private var extras: [OwnedExtra] {
        guard let target else { return [] }
        switch target {
        case .series(let resolved):
            return ExtraCollector.collect(.series(resolved.series))
        case .season(_, _, let scanned):
            guard let scanned else { return [] }
            return ExtraCollector.collect(.season(scanned))
        case .episode(let resolved):
            return ExtraCollector.collect(.episode(resolved.episode))
        }
    }

    private var visible: [OwnedExtra] {
        switch selection {
        case .all:
            extras
        case .folder(let name):
            extras.filter { $0.extra.folderName == name }
        case .filenameSuffix:
            extras.filter { $0.extra.folderName == nil }
        }
    }

    var body: some View {
        HSplitView {
            folderList
                .frame(minWidth: 190, idealWidth: 210, maxWidth: 300)
            extraList
                .frame(minWidth: 300, maxWidth: .infinity)
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: - Destinations

    private var folderList: some View {
        let counts = ExtraCollector.countsByFolder(extras)

        return List(selection: $selection) {
            Section("Extras") {
                row(label: "All", systemImage: "square.stack", count: extras.count)
                    .tag(ExtrasFilter.all)

                ForEach(counts.folders, id: \.folder.id) { entry in
                    row(
                        label: entry.folder.displayName,
                        systemImage: "folder",
                        count: entry.count,
                        dimmed: entry.count == 0
                    )
                    .tag(ExtrasFilter.folder(entry.folder.name))
                    .help("Files in a “\(entry.folder.name)” folder become \(entry.folder.type.displayName) extras.")
                    .listRowBackground(
                        dropTarget == entry.folder.name
                            ? Color.accentColor.opacity(0.25)
                            : Color.clear
                    )
                    .dropDestination(for: String.self) { items, _ in
                        // The payload is an entity id. Anything else dragged in
                        // from outside simply resolves to nothing and is refused,
                        // which is why no custom UTType is needed.
                        items.compactMap(UUID.init(uuidString:))
                            .reduce(false) { fileAsExtra($1, entry.folder) || $0 }
                    } isTargeted: { over in
                        dropTarget = over ? entry.folder.name : nil
                    }
                }

                // Suffix-bound extras belong to no folder, so they need a home in
                // this list or they would be unreachable from it.
                row(
                    label: "By filename suffix",
                    systemImage: "textformat",
                    count: counts.suffixCount,
                    dimmed: counts.suffixCount == 0
                )
                .tag(ExtrasFilter.filenameSuffix)
                .help("Bound to a sibling item by a suffix such as “-behindthescenes”.")
            }
        }
    }

    private func row(label: String, systemImage: String, count: Int, dimmed: Bool = false) -> some View {
        HStack {
            Label(label, systemImage: systemImage)
                .lineLimit(1)
            Spacer()
            Text("\(count)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .foregroundStyle(dimmed ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
    }

    // MARK: - Extras

    /// `Table` needs identity, and a file path is unique per extra. Kept out of the
    /// model so the choice of identifier stays a presentation concern.
    private struct Row: Identifiable {
        let owned: OwnedExtra
        var id: URL { owned.extra.file }
    }

    private var extraList: some View {
        Table(visible.map(Row.init)) {
            TableColumn("Title") { row in
                // Extras carry no NFO, so this filename is the on-screen title.
                Text(row.owned.extra.title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(row.owned.extra.file.path)
            }
            TableColumn("Type") { row in
                Text(row.owned.extra.type.displayName).foregroundStyle(.secondary)
            }
            .width(min: 110, ideal: 130)
            TableColumn("Belongs to") { row in
                Text(row.owned.ownerLabel)
                    .foregroundStyle(row.owned.isDirect ? .primary : .secondary)
            }
            .width(min: 90, ideal: 110)
            TableColumn("Filed under") { row in
                Text(row.owned.extra.folderName ?? "filename suffix")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .width(min: 100, ideal: 130)
        }
    }
}

/// Replaces what VSplitView would have given us, without letting it renegotiate
/// the widths of the browsing columns above.
struct ExtrasResizeHandle: View {
    @Binding var height: CGFloat
    @State private var heightAtDragStart: CGFloat?

    private static let range: ClosedRange<CGFloat> = 120...620

    var body: some View {
        ZStack {
            Divider()
            Rectangle()
                .fill(.clear)
                .frame(height: 8)
                .contentShape(.rect)
        }
        .frame(height: 8)
        .onHover { inside in
            if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
        }
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    let start = heightAtDragStart ?? height
                    heightAtDragStart = start
                    // Dragging up grows the drawer, so the translation is inverted.
                    height = min(max(start - value.translation.height, Self.range.lowerBound), Self.range.upperBound)
                }
                .onEnded { _ in heightAtDragStart = nil }
        )
    }
}
