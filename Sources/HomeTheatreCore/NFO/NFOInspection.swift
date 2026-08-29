import Foundation

/// What a tag does, so a reader can tell structure from description at a glance.
public enum NFOFieldRole: String, Sendable, Hashable {
    /// Drives provider matching: `<season>`, `<episode>`, `<seasonnumber>`.
    case identity
    /// Drives presentation: the display/airs tags and `<displayorder>`.
    case ordering
    /// `<lockdata>` — what stops a refresh overwriting the rest.
    case lock
    case other
}

/// Whether a tag's value survives Emby's parse.
public enum NFOFieldStatus: String, Sendable, Hashable {
    case normal
    /// This is the value Emby ends up using for its property.
    case effective
    /// A later tag writing the same property overwrote this one.
    case superseded
    /// Rejected: ordering values must be greater than zero.
    case discardedNonPositive
}

public struct NFOField: Sendable, Hashable {
    public var name: String
    public var value: String
    public var depth: Int
    public var role: NFOFieldRole
    public var status: NFOFieldStatus

    public var isIgnored: Bool {
        status == .superseded || status == .discardedNonPositive
    }
}

/// A read of one NFO file for display: the raw text plus its tags flattened in
/// document order, annotated with what each one does and whether it survives.
///
/// The annotation matters because two of Emby's rules are invisible in the file
/// itself. Ordering tags alias onto two properties, so a document holding both
/// `<displayseason>` and `<airsbefore_season>` silently discards one — and which
/// one depends purely on their order. Ordering values must also be greater than
/// zero, so a `<displayepisode>0</displayepisode>` does nothing at all despite
/// looking authoritative.
public struct NFOInspection: Sendable, Hashable {
    public var url: URL
    public var rootName: String
    public var rawText: String
    public var fields: [NFOField]

    static let identityTags: Set<String> = ["season", "episode", "episodenumberend", "seasonnumber"]
    static let lockTags: Set<String> = ["lockdata"]

    public static func load(contentsOf url: URL) throws -> NFOInspection {
        let data = try Data(contentsOf: url)
        let document = try NFODocument.parse(data: data)
        let rawText = String(data: data, encoding: .utf8)
            ?? String(decoding: data, as: UTF8.self)

        var fields: [NFOField] = []
        flatten(document.root.children, depth: 0, into: &fields)
        annotate(&fields)

        return NFOInspection(
            url: url,
            rootName: document.root.name,
            rawText: rawText,
            fields: fields
        )
    }

    private static func flatten(_ elements: [NFOElement], depth: Int, into fields: inout [NFOField]) {
        for element in elements {
            let name = element.name.lowercased()
            let role: NFOFieldRole =
                if identityTags.contains(name) { .identity }
                else if NFOFields.sortParentTags.contains(name)
                    || NFOFields.sortIndexTags.contains(name)
                    || name == "displayorder" { .ordering }
                else if lockTags.contains(name) { .lock }
                else { .other }

            fields.append(
                NFOField(
                    name: element.name,
                    value: element.trimmedText,
                    depth: depth,
                    role: role,
                    status: .normal
                )
            )
            flatten(element.children, depth: depth + 1, into: &fields)
        }
    }

    /// Marks, for each aliased property, which tag actually wins.
    private static func annotate(_ fields: inout [NFOField]) {
        annotate(&fields, aliasing: NFOFields.sortParentTags)
        annotate(&fields, aliasing: NFOFields.sortIndexTags)
    }

    private static func annotate(_ fields: inout [NFOField], aliasing tags: [String]) {
        let indices = fields.indices.filter { index in
            fields[index].depth == 0 && tags.contains(fields[index].name.lowercased())
        }
        guard !indices.isEmpty else { return }

        // Last positive value in document order is the one Emby keeps.
        let winner = indices.last { NFOFields.positive(fields[$0].value) != nil }

        for index in indices {
            if NFOFields.positive(fields[index].value) == nil {
                fields[index].status = .discardedNonPositive
            } else if index == winner {
                fields[index].status = .effective
            } else {
                fields[index].status = .superseded
            }
        }
    }
}
