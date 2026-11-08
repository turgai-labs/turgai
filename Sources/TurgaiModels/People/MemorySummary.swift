#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// What's remembered about the signed-in person, as their profile shows it: a tree of names, each
/// with what was said for it, when anything was, and the names under it.
public struct MemorySummary: Codable, Hashable, Sendable {
    public struct Node: Codable, Hashable, Sendable {
        public let name: String
        /// Its value, or each different one with when it was learned: none when the name only
        /// groups the ones under it.
        public let said: String?
        public let children: [Node]

        public init(name: String, said: String?, children: [Node]) {
            self.name = name
            self.said = said
            self.children = children
        }
    }

    /// The names right under the person.
    public let nodes: [Node]

    public init(nodes: [Node]) {
        self.nodes = nodes
    }
}
