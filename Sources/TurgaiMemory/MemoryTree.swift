/// What's remembered about a person, as a tree: under them, each name with the value of the fact at
/// its path, when there's one, and the names under it, in the order they were first learned.
public struct MemoryTree: Hashable, Codable, Sendable {
    public struct Node: Hashable, Codable, Sendable {
        public let name: MemoryName
        /// The fact at its path, when one is there: a name can also only group the ones under it.
        public let fact: MemoryFact?
        public let children: [Node]

        /// Its fact, then those under it.
        public var facts: [MemoryFact] {
            (fact.map { [$0] } ?? []) + children.flatMap(\.facts)
        }
    }

    /// The names right under the person.
    public let nodes: [Node]

    /// The tree of `facts`, one at each path.
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
                fact: under.first { $0.path.names.count == depth + 1 },
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
            let line = indent + (last ? "└─ " : "├─ ") + node.name.rawValue + (node.fact.map { ": \($0.value)" } ?? "")
            return [line] + lines(of: node.children, indent: indent + (last ? "   " : "│  "))
        }
    }
}
