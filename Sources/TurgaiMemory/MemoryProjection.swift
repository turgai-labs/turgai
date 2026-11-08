#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// A person's memory: whether what they say is remembered, and what is, with the messages it was
/// learned from.
///
/// The journal keeps full provenance; memory keeps only a bounded
/// tail of recent observations (extraction context) plus every fact with its
/// status, so a fact that ended stays, ended.
public struct Memory: Codable, Sendable, Equatable {
    /// The observation tail is hard-bounded; older observations remain in
    /// the journal, not in memory. `processedSources` is keyed by sourceID,
    /// so trimming the tail never un-marks a consumed source.
    public static let maximumObservations = 500

    public private(set) var generation: MemoryGeneration
    /// The logical boundary prevents delayed observations from a turn that
    /// predates `/forget` from re-entering the new generation.
    public private(set) var lastClearedAt: Date?
    public private(set) var observations: [MemoryObservation] = []
    public private(set) var processedSources: Set<MemorySourceID> = []
    public private(set) var facts: [MemoryFact] = []
    /// Whether what they say is remembered.
    public private(set) var remembering: Remembering = .on

    public var latestObservationSourceID: MemorySourceID? {
        Self.latestObservation(in: observations)?.sourceID
    }

    /// The latest durable observation is the last one appended to the user
    /// journal. Messages can finish model turns out of send-time order, so
    /// `observedAt` does not identify the newest extraction trigger.
    public static func latestObservation(
        in observations: [MemoryObservation]
    ) -> MemoryObservation? {
        observations.last
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
        case processedSources
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
        processedSources =
            try container.decodeIfPresent(
                Set<MemorySourceID>.self,
                forKey: .processedSources
            ) ?? []
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
        try container.encode(processedSources, forKey: .processedSources)
        try container.encode(facts, forKey: .facts)
        try container.encode(remembering, forKey: .remembering)
    }

    public mutating func apply(_ event: MemoryEvent) {
        switch event {
        case .cleared(let at):
            observations.removeAll(keepingCapacity: true)
            processedSources.removeAll(keepingCapacity: true)
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
            processedSources.formUnion(commit.processedSources)
            for observation in commit.observations {
                guard accepts(observation),
                    !observations.contains(where: { $0.sourceID == observation.sourceID })
                else { continue }
                appendObservation(observation)
            }
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

    /// The last `limit` observations before a source's, in journal order: none when it isn't here.
    public func previousObservations(
        before sourceID: MemorySourceID,
        limit: Int
    ) -> [MemoryObservation] {
        guard let index = observations.firstIndex(where: { $0.sourceID == sourceID }) else { return [] }
        return Array(observations[..<index].suffix(limit))
    }

    public func containsObservation(for sourceID: MemorySourceID) -> Bool {
        observations.contains { $0.sourceID == sourceID }
    }

    public func isProcessed(_ observation: MemoryObservation) -> Bool {
        processedSources.contains(observation.sourceID)
    }

    public func accepts(_ observation: MemoryObservation) -> Bool {
        guard let lastClearedAt else { return true }
        return observation.observedAt > lastClearedAt
    }
}
