#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// The materialized "what is current?" view over one user's memory events.
///
/// The journal keeps full provenance; this projection keeps only a bounded
/// tail of recent observations (extraction context) plus every fact with its
/// status, so contradictions stay visible after supersession.
public struct MemoryProjection: Codable, Sendable, Equatable {
    /// The observation tail is hard-bounded; older observations remain in
    /// the journal, not in memory. `processedSources` is keyed by sourceID,
    /// so trimming the tail never un-marks a consumed source.
    public static let maximumObservations = 500
    public static let maximumCurrentFacts = 50

    public private(set) var generation: MemoryGeneration
    /// The logical boundary prevents delayed observations from a turn that
    /// predates `/forget` from re-entering the new generation.
    public private(set) var lastClearedAt: Date?
    public private(set) var observations: [MemoryObservation] = []
    public private(set) var processedSources: Set<MemorySourceID> = []
    public private(set) var facts: [MemoryFact] = []

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

    public init(generation: MemoryGeneration = .initial) {
        self.generation = generation
        self.lastClearedAt = nil
    }

    private enum CodingKeys: String, CodingKey {
        case generation
        case lastClearedAt
        case observations
        case processedSources
        case facts
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
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(generation, forKey: .generation)
        try container.encodeIfPresent(lastClearedAt, forKey: .lastClearedAt)
        try container.encode(observations, forKey: .observations)
        try container.encode(processedSources, forKey: .processedSources)
        try container.encode(facts, forKey: .facts)
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

        case .factAccepted(let fact):
            applyFactEvent(.factAccepted(fact))

        case .factReinforced(let id, let evidence, let confidence):
            applyFactEvent(.factReinforced(id, evidence: evidence, confidence: confidence))

        case .factSuperseded(let id, let replacement):
            applyFactEvent(.factSuperseded(id, by: replacement))

        case .factExpired(let id):
            guard let index = facts.firstIndex(where: { $0.id == id }) else { return }
            facts[index].transition(to: .expired)

        case .factForgotten(let id):
            guard let index = facts.firstIndex(where: { $0.id == id }) else { return }
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
        }
    }

    private mutating func appendObservation(_ observation: MemoryObservation) {
        observations.append(observation)
        if observations.count > Self.maximumObservations {
            observations.removeFirst(observations.count - Self.maximumObservations)
        }
    }

    public mutating func applyFactEvent(_ event: MemoryFactEvent) {
        switch event {
        case .factAccepted(let fact):
            facts.append(fact)
        case .factReinforced(let id, let evidence, let confidence):
            guard let index = facts.firstIndex(where: { $0.id == id }) else { return }
            facts[index].reinforce(evidence: evidence, confidence: confidence)
        case .factSuperseded(let id, let replacement):
            if let index = facts.firstIndex(where: { $0.id == id }) {
                facts[index].transition(to: .superseded(by: replacement.id))
            }
            facts.append(replacement)
        }
    }

    /// Facts that may be shown to the model: active and not past their
    /// validity range. Defensive about `validUntil` even though expiration is
    /// event-driven — a restart may land after a deadline passed.
    public func currentFacts(now: Date = Date()) -> [MemoryFact] {
        facts.filter { fact in
            guard fact.status == .active else { return false }
            if let validUntil = fact.validUntil, validUntil < now { return false }
            return true
        }
    }

    public func currentFacts(
        limit: Int,
        now: Date = Date()
    ) -> [MemoryFact] {
        Array(
            currentFacts(now: now).suffix(
                min(max(0, limit), Self.maximumCurrentFacts)
            )
        )
    }

    public func activeFact(namespace: MemoryNamespace, predicate: String) -> MemoryFact? {
        facts.first {
            $0.status == .active
                && $0.namespace == namespace
                && $0.predicate == predicate
        }
    }

    public func recentObservations(limit: Int) -> [MemoryObservation] {
        Array(observations.suffix(limit))
    }

    /// Returns the observations that precede a source in journal order. The
    /// source is expected to have been recorded before extraction begins.
    public func previousObservations(
        before sourceID: MemorySourceID,
        limit: Int
    ) -> [MemoryObservation] {
        guard limit > 0,
            let index = observations.firstIndex(where: { $0.sourceID == sourceID })
        else {
            return recentObservations(limit: limit)
        }
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
