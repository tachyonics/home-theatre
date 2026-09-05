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

    var isEmpty: Bool { changeSet.isEmpty }
    var count: Int { changeSet.count }

    func add(_ action: PendingAction, to entity: EntityRef) {
        changeSet.add(action, to: entity)
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
