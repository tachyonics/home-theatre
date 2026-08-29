import HomeTheatreCore
import SwiftUI

/// Two panes: the extra types present for the selected item, and the extras of the
/// chosen type. Scope follows the same target as the details drawer.
struct ExtrasDrawer: View {
    let target: InspectorTarget?
    @Binding var selectedType: ExtraType?

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

    private var counts: [(type: ExtraType, count: Int)] {
        ExtraCollector.countsByType(extras)
    }

    private var visible: [OwnedExtra] {
        guard let selectedType else { return extras }
        return extras.filter { $0.extra.type == selectedType }
    }

    var body: some View {
        HSplitView {
            typeList
                .frame(minWidth: 170, idealWidth: 200, maxWidth: 280)
            extraList
                .frame(minWidth: 300, maxWidth: .infinity)
        }
        .frame(minHeight: 120)
        .overlay {
            if extras.isEmpty {
                ContentUnavailableView(
                    "No extras",
                    systemImage: "paperclip",
                    description: emptyDescription
                )
                .background(.background)
            }
        }
    }

    private var emptyDescription: Text {
        switch target {
        case .episode:
            Text("Nothing sits beside this episode. Extras bind by filename suffix or an SxxExx folder.")
        case .season, .series, .none:
            Text("Extras are recognised from folder names such as “behind the scenes”, or a filename suffix like “-deleted”.")
        }
    }

    // MARK: - Types

    private var typeList: some View {
        List(selection: $selectedType) {
            Section("Type") {
                // Tagged nil so clearing the filter is a normal selection.
                HStack {
                    Label("All", systemImage: "square.stack")
                    Spacer()
                    Text("\(extras.count)").foregroundStyle(.secondary).font(.caption)
                }
                .tag(ExtraType?.none)

                ForEach(counts, id: \.type) { entry in
                    HStack {
                        Text(entry.type.displayName)
                        Spacer()
                        Text("\(entry.count)").foregroundStyle(.secondary).font(.caption)
                    }
                    .tag(ExtraType?.some(entry.type))
                }
            }
        }
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
                let owned = row.owned
                // Extras carry no NFO, so this filename is the on-screen title.
                Text(owned.extra.title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(owned.extra.file.path)
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
            TableColumn("File") { row in
                Text(row.owned.extra.file.lastPathComponent)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }
}
