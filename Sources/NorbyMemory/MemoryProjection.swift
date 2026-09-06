import Foundation

/// The materialized "what is current?" view over one user's memory events.
///
/// The journal keeps full provenance; this projection keeps only a bounded
/// tail of recent observations (extraction context) plus every fact with its
/// status, so contradictions stay visible after supersession.
public struct MemoryProjection: Codable, Sendable, Equatable {
    /// Observations older than the tail remain in the journal, not in memory.
    public static let observationTailLimit = 100

    public private(set) var observations: [MemoryObservation] = []
    public private(set) var facts: [MemoryFact] = []

    public init() {}

    public mutating func apply(_ event: MemoryEvent) {
        switch event {
        case .observationRecorded(let observation):
            guard !observations.contains(where: {
                $0.id == observation.id || $0.sourceID == observation.sourceID
            }) else { return }
            observations.append(observation)
            if observations.count > Self.observationTailLimit {
                observations.removeFirst(observations.count - Self.observationTailLimit)
            }

        case .observationCompleted(let sourceID, let response):
            guard let index = observations.firstIndex(where: {
                $0.sourceID == sourceID
            }) else { return }
            guard observations[index].response == nil else { return }
            let observation = observations[index]
            observations[index] = MemoryObservation(
                id: observation.id,
                sourceID: observation.sourceID,
                text: observation.text,
                response: response,
                observedAt: observation.observedAt
            )

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

        case .factExpired(let id):
            guard let index = facts.firstIndex(where: { $0.id == id }) else { return }
            facts[index].transition(to: .expired)

        case .factForgotten(let id):
            guard let index = facts.firstIndex(where: { $0.id == id }) else { return }
            facts[index].transition(to: .forgotten)
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
}
