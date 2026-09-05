import Foundation

/// The entity a pending action hangs off, as the review window needs it.
///
/// The label is denormalised rather than looked up from the scan on demand, and
/// that is deliberate: applying a single action moves files on disk while the
/// scanned model still describes where they were, so anything rendering from the
/// live model would go wrong exactly when the user is halfway through a queue.
/// A copy of the name taken when the action was made cannot drift.
public struct EntityRef: Sendable, Hashable, Codable, Identifiable {
    public var id: UUID
    public var level: ItemLevel
    /// `Doctor Who (2005)`, `Season 1`, `S01E03` — what the entity is called on
    /// screen, not a path.
    public var label: String

    public init(id: UUID, level: ItemLevel, label: String) {
        self.id = id
        self.level = level
        self.label = label
    }
}

/// One filesystem operation — a *part* of an action, never an action itself.
///
/// Steps carry absolute URLs rather than referring back to the entity, so a queued
/// action stays applicable even though the model that produced it has gone stale.
/// This is what lets actions be applied one at a time without a rescan between them.
public enum FileStep: Sendable, Hashable, Codable {
    /// Missing intermediate directories are created, which is how a file lands in
    /// an extras folder that does not exist yet.
    case move(from: URL, to: URL)
    /// To the Trash, never unlinked — see ``ChangeExecutor``.
    case trash(URL)

    public var sourceFile: URL {
        switch self {
        case .move(let from, _): from
        case .trash(let url): url
        }
    }

    /// One line for the review list: `Doctor Who S01E03.eng.srt → featurettes/`.
    public var summary: String {
        switch self {
        case .move(let from, let to):
            "\(from.lastPathComponent) → \(to.deletingLastPathComponent().lastPathComponent)/"
        case .trash(let url):
            "\(url.lastPathComponent) → Trash"
        }
    }
}

/// One thing the user decided, which may take several file operations to carry out.
///
/// The unit here is *intent*, not mechanism. "Set as Featurette extra" is a single
/// judgement even though it moves the video, its NFO, its thumb and each subtitle
/// track — and those moves are meaningless apart from each other, so offering them
/// individually would invite exactly the half-finished state that breaks a library:
/// a video filed as an extra with its subtitles left behind in the season.
///
/// Independent decisions stay independent actions. Two different reclassifications,
/// or a reclassification and an aired-date change, are separate rows that can be
/// applied or dropped on their own.
public struct PendingAction: Sendable, Hashable, Codable, Identifiable {
    public var id = UUID()
    /// What was decided, in the user's terms: `Set as Featurette extra`.
    public var title: String
    /// Where or how, when the title alone is ambiguous — two extras folders can
    /// share a type, so the folder has to be nameable separately.
    public var detail: String
    /// Carried out in order, all or nothing.
    public var steps: [FileStep]

    public init(title: String, detail: String = "", steps: [FileStep]) {
        self.title = title
        self.detail = detail
        self.steps = steps
    }
}

/// Everything queued, grouped by entity, in the order it was queued.
///
/// Insertion order rather than sorted: the queue is a record of what the user did,
/// and re-sorting it under them as they work would make a reviewable list harder to
/// review, not easier.
public struct ChangeSet: Sendable, Codable {
    /// Entities that currently have at least one action, oldest first.
    public private(set) var entities: [EntityRef] = []
    private var actionsByEntity: [UUID: [PendingAction]] = [:]

    public init() {}

    public var isEmpty: Bool { entities.isEmpty }

    /// Actions, not steps — what the toolbar counts, because an action is what the
    /// user queued.
    public var count: Int { actionsByEntity.values.reduce(0) { $0 + $1.count } }

    public func actions(for entity: EntityRef) -> [PendingAction] {
        actions(forEntityID: entity.id)
    }

    /// The id alone is enough to find them: an `EntityRef`'s label is for display
    /// and plays no part in identity.
    public func actions(forEntityID id: UUID) -> [PendingAction] {
        actionsByEntity[id] ?? []
    }

    public mutating func add(_ action: PendingAction, to entity: EntityRef) {
        guard !action.steps.isEmpty else { return }
        if actionsByEntity[entity.id] == nil {
            entities.append(entity)
            actionsByEntity[entity.id] = []
        }
        actionsByEntity[entity.id]?.append(action)
    }

    /// Drops one action, and the entity with it once its last action is gone —
    /// an entity heading with nothing under it is noise in a review list.
    public mutating func remove(actionID: UUID) {
        for entity in entities {
            guard var list = actionsByEntity[entity.id], list.contains(where: { $0.id == actionID }) else { continue }
            list.removeAll { $0.id == actionID }
            if list.isEmpty {
                actionsByEntity[entity.id] = nil
                entities.removeAll { $0.id == entity.id }
            } else {
                actionsByEntity[entity.id] = list
            }
            return
        }
    }

    public mutating func remove(entityID: UUID) {
        actionsByEntity[entityID] = nil
        entities.removeAll { $0.id == entityID }
    }

    public mutating func removeAll() {
        entities.removeAll()
        actionsByEntity.removeAll()
    }

    /// Every action with the entity it belongs to, in queue order — what "apply
    /// all" walks.
    public var allActions: [(entity: EntityRef, action: PendingAction)] {
        entities.flatMap { entity in
            actions(for: entity).map { (entity, $0) }
        }
    }
}
