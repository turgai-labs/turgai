#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// What's remembered about a person, as a tree: under them, each name with the value of the fact at
/// its path, when there's one, and the names under it, in the order they were first learned. The
/// tree of a human's linked persons holds each one's fact at a path, where they differ.
public struct MemoryTree: Hashable, Codable, Sendable {
    public struct Node: Hashable, Codable, Sendable {
        public let name: MemoryName
        /// The facts at its path: one in a person's own memory, none when a name only groups the
        /// ones under it, and one from each linked person who remembers it.
        public let here: [MemoryFact]
        public let children: [Node]

        /// Its facts, then those under it.
        public var facts: [MemoryFact] {
            here + children.flatMap(\.facts)
        }

        /// Its value as a line says it: the one value, or each different one with when it was
        /// learned, the earliest first.
        var said: String? {
            var values: [MemoryFact] = []
            for fact in here.sorted(by: { $0.observedAt < $1.observedAt })
            where !values.contains(where: { $0.value == fact.value }) {
                values.append(fact)
            }
            guard let only = values.first else { return nil }
            guard values.count > 1 else { return only.value }
            return values.map { "\($0.value) (\($0.observedAt.formatted(.iso8601.year().month().day())))" }
                .joined(separator: " · ")
        }
    }

    /// The names right under the person.
    public let nodes: [Node]

    /// The tree of `facts`: one at each path in a person's own memory.
    public init(_ facts: [MemoryFact]) {
        self.nodes = Self.nodes(of: facts, at: 0)
    }

    private static func nodes(of facts: [MemoryFact], at depth: Int) -> [Node] {
        var names: [MemoryName] = []
        for fact in facts where fact.path.names.count > depth && !names.contains(fact.path.names[depth]) {
            names.append(fact.path.names[depth])
        }
        return names.map { name in
            let under = facts.filter { $0.path.names.count > depth && $0.path.names[depth] == name }
            return Node(
                name: name,
                here: under.filter { $0.path.names.count == depth + 1 },
                children: nodes(of: under, at: depth + 1))
        }
    }

    public var isEmpty: Bool {
        nodes.isEmpty
    }

    /// Every fact in it, in the tree's order.
    public var facts: [MemoryFact] {
        nodes.flatMap(\.facts)
    }

    /// As text: `root`, then a line for each name, drawn as a tree under it.
    public func rendered(root: String = "You") -> String {
        ([root] + Self.lines(of: nodes, indent: "")).joined(separator: "\n")
    }

    private static func lines(of nodes: [Node], indent: String) -> [String] {
        nodes.enumerated().flatMap { index, node in
            let last = index == nodes.count - 1
            let line = indent + (last ? "└─ " : "├─ ") + node.name.rawValue + (node.said.map { ": \($0)" } ?? "")
            return [line] + lines(of: node.children, indent: indent + (last ? "   " : "│  "))
        }
    }
}
