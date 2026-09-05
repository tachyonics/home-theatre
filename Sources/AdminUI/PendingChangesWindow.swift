import HomeTheatreCore
import SwiftUI

/// The review window: entities on the left, that entity's actions on the right.
///
/// Two levels, and only two. An **entity** is what a change is about; an **action**
/// is one decision made about it, and is the smallest thing that can be applied or
/// dropped. The file operations an action performs are shown underneath it as
/// detail — they are how it happens, not separate choices, and offering them
/// individually would invite an episode filed as an extra with its subtitles left
/// behind.
struct PendingChangesView: View {
    @Environment(ChangeStore.self) private var store

    @State private var selection: UUID?

    var body: some View {
        NavigationSplitView {
            entityList
                .navigationSplitViewColumnWidth(min: 220, ideal: 280)
        } detail: {
            actionList
        }
        .navigationTitle("Pending Changes")
        .toolbar { toolbarContent }
        .frame(minWidth: 720, minHeight: 380)
        .overlay { if store.isEmpty { emptyState } }
    }

    // MARK: - Entities

    private var entityList: some View {
        List(selection: $selection) {
            Section("Entities") {
                ForEach(store.changeSet.entities) { entity in
                    row(for: entity)
                        .tag(entity.id)
                        .contextMenu {
                            Button("Apply All for \(entity.label)") {
                                _ = store.apply(store.actions(for: entity))
                            }
                            Button("Delete All for \(entity.label)", role: .destructive) {
                                store.remove(entityID: entity.id)
                            }
                        }
                }
            }
        }
    }

    private func row(for entity: EntityRef) -> some View {
        let actions = store.actions(for: entity)
        let failed = actions.count { store.failure(for: $0) != nil }

        return VStack(alignment: .leading, spacing: 3) {
            Text(entity.label)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                Text(entity.level.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("\(actions.count) action\(actions.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                if failed > 0 {
                    Badge("\(failed) failed", tone: .warning)
                }
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Actions

    private var selectedEntity: EntityRef? {
        store.changeSet.entities.first { $0.id == selection }
            // A selection can outlive the entity it named — applying its last
            // action removes it — so fall back rather than showing a blank pane.
            ?? store.changeSet.entities.first
    }

    @ViewBuilder
    private var actionList: some View {
        if let entity = selectedEntity {
            List {
                Section(entity.label) {
                    ForEach(store.actions(for: entity)) { action in
                        actionRow(action)
                            .contextMenu {
                                Button("Apply") { store.apply(action) }
                                Button("Delete", role: .destructive) { store.remove(actionID: action.id) }
                            }
                    }
                }
            }
        } else if !store.isEmpty {
            ContentUnavailableView("No entity selected", systemImage: "square.stack")
        }
    }

    private func actionRow(_ action: PendingAction) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(action.title)
                    .fontWeight(.medium)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                if !action.detail.isEmpty {
                    Text(action.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 8)

                Text("\(action.steps.count) file\(action.steps.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            // Shown, but as one block belonging to the action above: this is what
            // will happen, not a menu of what could.
            VStack(alignment: .leading, spacing: 1) {
                ForEach(Array(action.steps.enumerated()), id: \.offset) { _, step in
                    Text(step.summary)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
            .padding(.leading, 10)

            if let failure = store.failure(for: action) {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Chrome

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup {
            Spacer()

            Text("\(store.count) pending")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            Button(role: .destructive) {
                store.removeAll()
            } label: {
                Label("Discard All", systemImage: "trash")
            }
            .disabled(store.isEmpty)
            .help("Discard every queued action without touching the disk.")

            Button {
                _ = store.applyAll()
            } label: {
                Label("Apply All Changes", systemImage: "checkmark.circle")
            }
            .buttonStyle(.borderedProminent)
            .disabled(store.isEmpty)
            .help("Perform every queued action, in order, reporting any that fail.")
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Nothing pending", systemImage: "tray")
        } description: {
            Text("Drag an episode onto an extras folder to queue a change.")
        }
    }
}
