#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// What's remembered about a person: a line for each relation they have, in the order relations are
/// listed, with whom or what they're related to that way, the earliest learned first. A human's
/// linked persons are remembered in one.
public struct Remembered: Hashable, Codable, Sendable {
    public struct Line: Hashable, Codable, Sendable {
        public let relation: MemoryRelation
        public let facts: [MemoryFact]

        /// Whom or what, each once: `pasta · sushi`.
        public var said: String {
            var names: [MemoryName] = []
            for fact in facts where !names.contains(where: { $0.isSame(as: fact.to) }) {
                names.append(fact.to)
            }
            return names.map(\.rawValue).joined(separator: " · ")
        }
    }

    public let lines: [Line]

    /// What `facts` remember.
    public init(_ facts: [MemoryFact]) {
        let learned = facts.sorted { $0.learned.at < $1.learned.at }
        self.lines = MemoryRelation.allCases.compactMap { relation in
            let theirs = learned.filter { $0.relation == relation }
            return theirs.isEmpty ? nil : Line(relation: relation, facts: theirs)
        }
    }

    public var isEmpty: Bool {
        lines.isEmpty
    }

    /// Every fact in it, in its lines' order.
    public var facts: [MemoryFact] {
        lines.flatMap(\.facts)
    }
}
