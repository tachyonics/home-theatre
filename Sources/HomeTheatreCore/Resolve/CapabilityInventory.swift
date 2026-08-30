import Foundation

/// The full capability list for one item, present or not.
///
/// Missing capabilities are kept in the list deliberately, the same way the extras
/// pane keeps every folder Emby recognises: a curation tool is mostly used to find
/// what is *not* there, and a list that quietly omits the poster you have not
/// supplied cannot tell you it is missing.
public enum CapabilityInventory: Sendable {
    public struct Entry: Sendable, Hashable, Identifiable {
        public var capability: Capability
        public var level: ItemLevel
        /// The files behind this capability. Empty for ``Capability/details``,
        /// which is backed by `nfoURL`.
        public var assets: [MediaAsset]
        public var nfoURL: URL?

        public var id: Capability { capability }

        public var displayName: String { capability.displayName(at: level) }

        public var count: Int {
            switch capability {
            case .details: nfoURL == nil ? 0 : 1
            default: assets.count
            }
        }

        public var isPresent: Bool { count > 0 }

        /// Files Emby will never look at because a higher-precedence filename for
        /// the same capability sits beside them.
        public var shadowedCount: Int { assets.count { $0.isShadowed } }

        /// What the picker puts beside the name — short, and explicit about
        /// absence rather than showing a bare zero.
        public var countLabel: String {
            switch capability {
            case .details: isPresent ? "present" : "missing"
            default: isPresent ? "\(count) file\(count == 1 ? "" : "s")" : "missing"
            }
        }
    }

    public static func entries(
        level: ItemLevel,
        nfoURL: URL? = nil,
        assets: [MediaAsset] = []
    ) -> [Entry] {
        Capability.applicable(to: level).map { capability in
            Entry(
                capability: capability,
                level: level,
                assets: assets.filter { $0.capability == capability },
                nfoURL: capability == .details ? nfoURL : nil
            )
        }
    }

    /// `Series Details, Poster, Backdrop ×3` — the present capabilities only,
    /// for the text report, where the missing ones would be pure noise.
    public static func summary(_ entries: [Entry]) -> String {
        entries
            .filter(\.isPresent)
            .map { $0.count > 1 ? "\($0.displayName) ×\($0.count)" : $0.displayName }
            .joined(separator: ", ")
    }
}
