// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the home-silo project authors

import HomeTheatreCore
import SwiftUI

/// The queue of pending actions, shared between the browser window and the
/// Pending Changes window.
///
/// One instance is injected into the environment from `AdminUIApp`, because the two
/// windows are separate scenes: state held in `ContentView` cannot be reached from
/// the other window at all.
@MainActor
@Observable
final class ChangeStore {
    /// Named `changeSet` rather than `set`: inside a computed property, `set` reads
    /// as the setter keyword and the file stops parsing.
    private(set) var changeSet = ChangeSet()

    /// Failures from the last apply, kept against the action that failed so the row
    /// can explain itself rather than the whole queue reporting one banner.
    private(set) var failures: [UUID: String] = [:]

    /// What has been carried out since the scan was taken.
    ///
    /// An applied action leaves the queue but the disk keeps its effect, and the
    /// scan the browser draws from still describes the tree as it was before. So
    /// the actions are kept, under the entities they were made against, for the
    /// browser to advance its own model past — otherwise applying would look like
    /// it had undone itself, the change vanishing from the queue and the library
    /// snapping back to the state the user had just changed.
    private(set) var applied = ChangeSet()

    /// Changes on every successful apply, which is what a view watches to know its
    /// model has fallen behind the disk.
    var appliedCount: Int { applied.count }

    var isEmpty: Bool { changeSet.isEmpty }
    var count: Int { changeSet.count }

    func add(_ action: PendingAction, to entity: EntityRef) {
        changeSet.add(action, to: entity)
    }

    /// Queues a filing, replacing the one already queued for the same entity —
    /// see ``ChangeSet/file(_:for:)`` for why a second filing supersedes rather
    /// than stacks.
    func file(_ action: PendingAction, to entity: EntityRef) {
        for superseded in changeSet.filings(forEntityID: entity.id) {
            failures[superseded.id] = nil
        }
        changeSet.file(action, for: entity)
    }

    /// Undoes a queued filing. False when there was none, so a drop that means
    /// nothing can be refused rather than silently accepted.
    @discardableResult
    func cancelFilings(forEntityID id: UUID) -> Bool {
        let cancelled = changeSet.removeFilings(forEntityID: id)
        for action in cancelled { failures[action.id] = nil }
        return !cancelled.isEmpty
    }

    func remove(actionID: UUID) {
        changeSet.remove(actionID: actionID)
        failures[actionID] = nil
    }

    func remove(entityID: UUID) {
        for action in changeSet.actions(forEntityID: entityID) {
            failures[action.id] = nil
        }
        changeSet.remove(entityID: entityID)
    }

    /// Discards everything. Called when a rescan is confirmed: the queue was built
    /// against entity ids the new scan will not reissue.
    func removeAll() {
        changeSet.removeAll()
        applied.removeAll()
        failures.removeAll()
    }

    /// Applies one action, dropping it on success and recording why on failure.
    ///
    /// A failed action stays in the queue deliberately — it is the one the user now
    /// has to decide about, and silently discarding it would hide the decision. Its
    /// steps have been rolled back, so what stays queued still describes the tree as
    /// it currently is.
    @discardableResult
    func apply(_ action: PendingAction) -> Bool {
        switch ChangeExecutor.apply(action) {
        case .success:
            // Recorded before the removal, which is what still knows the entity.
            if let entity = changeSet.entity(owningActionID: action.id) {
                applied.add(action, to: entity)
            }
            changeSet.remove(actionID: action.id)
            failures[action.id] = nil
            return true
        case .failure(let error):
            failures[action.id] = error.description
            return false
        }
    }

    /// Applies actions in queue order, continuing past failures.
    @discardableResult
    func apply(_ actions: [PendingAction]) -> (applied: Int, failed: Int) {
        var applied = 0
        var failed = 0
        for action in actions {
            if apply(action) { applied += 1 } else { failed += 1 }
        }
        return (applied, failed)
    }

    func applyAll() -> (applied: Int, failed: Int) {
        apply(changeSet.allActions.map(\.action))
    }

    func actions(for entity: EntityRef) -> [PendingAction] {
        changeSet.actions(for: entity)
    }

    func failure(for action: PendingAction) -> String? {
        failures[action.id]
    }
}
