import Foundation

public enum ChangeError: Error, Sendable, Hashable, CustomStringConvertible {
    case sourceMissing(URL)
    case destinationExists(URL)
    case failed(String)
    /// A step failed and undoing the steps already done failed too, so the entity
    /// is now split across two places. Stated separately because it is the one
    /// outcome that needs a human immediately.
    case rollbackFailed(step: String, detail: String)

    public var description: String {
        switch self {
        case .sourceMissing(let url):
            "\(url.lastPathComponent) is no longer there"
        case .destinationExists(let url):
            "\(url.lastPathComponent) already exists at the destination"
        case .failed(let detail):
            detail
        case .rollbackFailed(let step, let detail):
            "\(step) failed and could not be undone — files are now split between locations (\(detail))"
        }
    }
}

/// Carries out a queued action against the filesystem.
///
/// Three rules, all about not being clever:
///
/// 1. **All or nothing.** An action's steps only make sense together — a video
///    filed as an extra with its subtitles left behind in the season is worse than
///    nothing having happened. A step that fails undoes the ones already done.
/// 2. **Refuse rather than clobber.** Every step checks that its source exists and
///    its destination does not. A queue is reviewed before it is applied, and the
///    review is worth nothing if applying it can silently overwrite something the
///    review never mentioned.
/// 3. **Nothing is unlinked.** Deletion means the Trash, so every operation here is
///    recoverable by hand. A tool that reorganises a media library is one bad drag
///    away from destroying something irreplaceable.
///
/// Failures come back as values rather than thrown, because applying twelve actions
/// has to report eleven successes and one failure — not abort in the middle and
/// leave the user guessing which half happened.
public enum ChangeExecutor {
    public static func apply(_ action: PendingAction) -> Result<Void, ChangeError> {
        var completed: [Completed] = []

        for step in action.steps {
            switch perform(step) {
            case .success(let record):
                completed.append(record)
            case .failure(let error):
                if let rollbackDetail = rollBack(completed) {
                    return .failure(.rollbackFailed(step: step.summary, detail: rollbackDetail))
                }
                return .failure(error)
            }
        }
        return .success(())
    }

    /// What a completed step needs in order to be undone.
    private enum Completed {
        case moved(from: URL, to: URL)
        /// `inTrash` is where the Trash actually put it, which is not derivable —
        /// the Finder renames on collision.
        case trashed(original: URL, inTrash: URL?)
    }

    private static func perform(_ step: FileStep) -> Result<Completed, ChangeError> {
        let manager = FileManager.default

        switch step {
        case .move(let from, let to):
            guard manager.fileExists(atPath: from.path) else {
                return .failure(.sourceMissing(from))
            }
            guard !manager.fileExists(atPath: to.path) else {
                return .failure(.destinationExists(to))
            }
            do {
                // The extras folder list deliberately shows folders that do not
                // exist yet, so filing into one has to be able to create it.
                try manager.createDirectory(
                    at: to.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try manager.moveItem(at: from, to: to)
                return .success(.moved(from: from, to: to))
            } catch {
                return .failure(.failed(error.localizedDescription))
            }

        case .trash(let url):
            guard manager.fileExists(atPath: url.path) else {
                return .failure(.sourceMissing(url))
            }
            do {
                var landed: NSURL?
                try manager.trashItem(at: url, resultingItemURL: &landed)
                return .success(.trashed(original: url, inTrash: landed as URL?))
            } catch {
                return .failure(.failed(error.localizedDescription))
            }
        }
    }

    /// Undoes completed steps, newest first. Returns a description of what could
    /// not be undone, or nil when the tree is back as it was.
    private static func rollBack(_ completed: [Completed]) -> String? {
        let manager = FileManager.default

        for record in completed.reversed() {
            do {
                switch record {
                case .moved(let from, let to):
                    try manager.moveItem(at: to, to: from)
                case .trashed(let original, let inTrash):
                    guard let inTrash else {
                        return "\(original.lastPathComponent) is in the Trash and must be put back by hand"
                    }
                    try manager.moveItem(at: inTrash, to: original)
                }
            } catch {
                return error.localizedDescription
            }
        }
        return nil
    }
}
