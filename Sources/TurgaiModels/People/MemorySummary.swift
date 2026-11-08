#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// What's remembered about the signed-in person, as their profile shows it: a tree of names, each
/// with what was said for it, when anything was, and the names under it; and whether what they say
/// is remembered.
public struct MemorySummary: Codable, Hashable, Sendable {
    /// Whether what they say is remembered. Off, nothing new is kept, and what is stays until it's
    /// forgotten.
    public enum Remembering: String, Codable, Hashable, Sendable {
        case on
        case off
    }

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
    public let remembering: Remembering

    public init(nodes: [Node], remembering: Remembering) {
        self.nodes = nodes
        self.remembering = remembering
    }
}

/// Remembering what the signed-in person says turned on or off.
public struct SetRememberingRequest: Codable, Hashable, Sendable {
    public let remembering: MemorySummary.Remembering

    public init(remembering: MemorySummary.Remembering) {
        self.remembering = remembering
    }
}
