import Foundation

/// A minimal ordered XML tree.
///
/// Everything is retained — element order, unrecognised elements, attributes — so
/// that a later write path can merge managed fields back in without destroying
/// data Emby (or anything else) put there. Regenerating an NFO from scratch is
/// the easiest way to lose metadata, so the parse is deliberately lossless.
public struct NFOElement: Sendable, Hashable {
    public var name: String
    public var attributes: [String: String]
    public var text: String
    public var children: [NFOElement]

    public init(name: String, attributes: [String: String] = [:], text: String = "", children: [NFOElement] = []) {
        self.name = name
        self.attributes = attributes
        self.text = text
        self.children = children
    }

    /// First direct child with this name, case-insensitively.
    public func child(_ name: String) -> NFOElement? {
        children.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    public func children(_ name: String) -> [NFOElement] {
        children.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    public func string(_ name: String) -> String? {
        guard let value = child(name)?.trimmedText, !value.isEmpty else { return nil }
        return value
    }

    public func int(_ name: String) -> Int? {
        guard let value = string(name) else { return nil }
        return Int(value)
    }

    public func bool(_ name: String) -> Bool? {
        guard let value = string(name)?.lowercased() else { return nil }
        return value == "true" || value == "1" || value == "yes"
    }

    public var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct NFODocument: Sendable {
    public var root: NFOElement
    public var url: URL?

    public init(root: NFOElement, url: URL? = nil) {
        self.root = root
        self.url = url
    }

    public static func parse(contentsOf url: URL) throws -> NFODocument {
        let data = try Data(contentsOf: url)
        var doc = try parse(data: data)
        doc.url = url
        return doc
    }

    public static func parse(data: Data) throws -> NFODocument {
        let builder = TreeBuilder()
        let parser = XMLParser(data: data)
        parser.delegate = builder
        parser.shouldProcessNamespaces = false
        guard parser.parse(), let root = builder.root else {
            throw NFOError.malformed(parser.parserError?.localizedDescription ?? "unparseable XML")
        }
        return NFODocument(root: root)
    }
}

public enum NFOError: Error, CustomStringConvertible {
    case malformed(String)

    public var description: String {
        switch self {
        case .malformed(let detail): "Malformed NFO: \(detail)"
        }
    }
}

/// XMLParser is a class-based push API, so the tree is assembled with a stack.
private final class TreeBuilder: NSObject, XMLParserDelegate {
    var root: NFOElement?
    private var stack: [NFOElement] = []

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        stack.append(NFOElement(name: elementName, attributes: attributeDict))
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard !stack.isEmpty else { return }
        stack[stack.count - 1].text += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        guard let finished = stack.popLast() else { return }
        if stack.isEmpty {
            root = finished
        } else {
            stack[stack.count - 1].children.append(finished)
        }
    }
}
