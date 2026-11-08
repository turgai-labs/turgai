import TurgaiDomain

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// A person's memory: whether what they say is remembered, and what is, with the exchanges it was
/// learned from; and how far into each of their conversations it's read.
///
/// The journal keeps full provenance; memory keeps only a bounded
/// tail of recent observations (extraction context) plus every fact with its
/// status, so a fact that ended stays, ended.
public struct Memory: Codable, Sendable, Equatable {
    /// The observation tail is hard-bounded; older observations remain in the journal, not in
    /// memory. A conversation's exchanges are read in the order they're kept, so one whose cursor
    /// was trimmed away has every exchange still kept after it.
    public static let maximumObservations = 500

    public private(set) var generation: MemoryGeneration
    /// The logical boundary prevents delayed observations from a turn that
    /// predates `/forget` from re-entering the new generation.
    public private(set) var lastClearedAt: Date?
    public private(set) var observations: [MemoryObservation] = []
    /// Each conversation's cursor: the last of its exchanges read.
    public private(set) var readThrough: [ConversationID: MemorySourceID] = [:]
    public private(set) var facts: [MemoryFact] = []
    /// Whether what they say is remembered.
    public private(set) var remembering: Remembering = .on

    /// The latest exchange in `conversation`: the last kept, since turns can finish out of the order
    /// their messages were sent in.
    public func latestObservation(in conversation: ConversationID) -> MemoryObservation? {
        observations.last { $0.conversation == conversation }
    }

    public init(generation: MemoryGeneration = .initial, remembering: Remembering = .on) {
        self.generation = generation
        self.lastClearedAt = nil
        self.remembering = remembering
    }

    private enum CodingKeys: String, CodingKey {
        case generation
        case lastClearedAt
        case observations
        case readThrough
        case facts
        case remembering
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        generation =
            try container.decodeIfPresent(
                MemoryGeneration.self,
                forKey: .generation
            ) ?? .initial
        lastClearedAt = try container.decodeIfPresent(
            Date.self,
            forKey: .lastClearedAt
        )
        observations =
            try container.decodeIfPresent(
                [MemoryObservation].self,
                forKey: .observations
            ) ?? []
        readThrough =
            try container.decodeIfPresent(
                [ConversationID: MemorySourceID].self,
                forKey: .readThrough
            ) ?? [:]
        facts =
            try container.decodeIfPresent(
                [MemoryFact].self,
                forKey: .facts
            ) ?? []
        remembering = try container.decode(Remembering.self, forKey: .remembering)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(generation, forKey: .generation)
        try container.encodeIfPresent(lastClearedAt, forKey: .lastClearedAt)
        try container.encode(observations, forKey: .observations)
        try container.encode(readThrough, forKey: .readThrough)
        try container.encode(facts, forKey: .facts)
        try container.encode(remembering, forKey: .remembering)
    }

    public mutating func apply(_ event: MemoryEvent) {
        switch event {
        case .cleared(let at):
            observations.removeAll(keepingCapacity: true)
            readThrough.removeAll(keepingCapacity: true)
            facts.removeAll(keepingCapacity: true)
            generation = generation.advancing()
            lastClearedAt = max(lastClearedAt ?? at, at)

        case .observationRecorded(let observation):
            guard
                !observations.contains(where: {
                    $0.id == observation.id || $0.sourceID == observation.sourceID
                })
            else { return }
            appendObservation(observation)

        case .factForgotten(let id):
            guard let index = facts.firstIndex(where: { $0.id == id && $0.status == .current }) else { return }
            facts[index].transition(to: .forgotten)

        case .extractionCommitted(let commit):
            guard commit.generation == generation else { return }
            readThrough[commit.conversation] = commit.readThrough
            for change in commit.changes {
                applyFactEvent(change)
            }

        case .rememberingChanged(let remembering):
            self.remembering = remembering
        }
    }

    private mutating func appendObservation(_ observation: MemoryObservation) {
        observations.append(observation)
        if observations.count > Self.maximumObservations {
            observations.removeFirst(observations.count - Self.maximumObservations)
        }
    }

    mutating func applyFactEvent(_ event: MemoryFactEvent) {
        switch event {
        case .learned(let fact):
            facts.append(fact)
        case .ended(let id, let said):
            guard let index = facts.firstIndex(where: { $0.id == id && $0.status == .current }) else { return }
            facts[index].transition(to: .ended(said))
        }
    }

    /// The facts that are true now, in the order they were learned.
    public func currentFacts() -> [MemoryFact] {
        facts.filter { $0.status == .current }
    }

    /// What's remembered now, as a tree.
    public var tree: MemoryTree {
        MemoryTree(currentFacts())
    }

    /// The exchanges in `conversation` past its cursor: all of them, before any is read.
    public func unread(in conversation: ConversationID) -> [MemoryObservation] {
        let (theirs, cursor) = exchanges(in: conversation)
        return Array(theirs[(cursor.map { $0 + 1 } ?? theirs.startIndex)...])
    }

    /// The last `limit` exchanges in `conversation` up to its cursor: none before any is read.
    public func read(in conversation: ConversationID, last limit: Int) -> [MemoryObservation] {
        let (theirs, cursor) = exchanges(in: conversation)
        guard let cursor else { return [] }
        return Array(theirs[...cursor].suffix(limit))
    }

    /// The exchanges kept in `conversation`, and where its cursor is among them: none when nothing's
    /// read, or what was is no longer kept.
    private func exchanges(in conversation: ConversationID) -> (theirs: [MemoryObservation], cursor: Int?) {
        let theirs = observations.filter { $0.conversation == conversation }
        let cursor = readThrough[conversation].flatMap { read in theirs.firstIndex { $0.sourceID == read } }
        return (theirs, cursor)
    }

    public func containsObservation(for sourceID: MemorySourceID) -> Bool {
        observations.contains { $0.sourceID == sourceID }
    }

    public func accepts(_ observation: MemoryObservation) -> Bool {
        guard let lastClearedAt else { return true }
        return observation.observedAt > lastClearedAt
    }
}
