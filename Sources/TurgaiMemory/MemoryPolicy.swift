#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// The result of applying deterministic memory policy to one extractor
/// proposal. A rejected proposal produces no journal event.
public enum MemoryDecision: Hashable, Sendable {
    case rejected
    case accepted(MemoryFact)
    case reinforced(
        factID: MemoryFactID,
        evidence: [ObservationID],
        confidence: Double
    )
    case superseded(oldFactID: MemoryFactID, replacement: MemoryFact)

    public var event: MemoryEvent? {
        switch self {
        case .rejected:
            nil
        case .accepted(let fact):
            .factAccepted(fact)
        case .reinforced(let factID, let evidence, let confidence):
            .factReinforced(factID, evidence: evidence, confidence: confidence)
        case .superseded(let oldFactID, let replacement):
            .factSuperseded(oldFactID, by: replacement)
        }
    }

    public var factEvent: MemoryFactEvent? {
        switch self {
        case .rejected:
            nil
        case .accepted(let fact):
            .factAccepted(fact)
        case .reinforced(let factID, let evidence, let confidence):
            .factReinforced(factID, evidence: evidence, confidence: confidence)
        case .superseded(let oldFactID, let replacement):
            .factSuperseded(oldFactID, by: replacement)
        }
    }
}

public enum MemoryCommitDecision: Sendable, Equatable {
    case stale
    case alreadyHandled
    case commit(MemoryExtractionCommit)
}

/// Namespace for the pure memory-extraction decisions.
public enum MemoryExtraction {
    /// Reconciles one captured extraction against one memory snapshot.
    /// No actor state or journal is consulted while this function runs.
    public static func decide(
        state: Memory,
        input: ExtractionInput,
        candidates: [FactCandidate],
        policy: MemoryPolicy = MemoryPolicy()
    ) -> MemoryCommitDecision {
        guard input.generation == state.generation else { return .stale }
        guard input.observations.allSatisfy(state.accepts) else { return .stale }

        let observations = input.observations + input.previousObservations
        guard !input.observations.isEmpty,
            !input.observations.allSatisfy(state.isProcessed)
        else {
            return .alreadyHandled
        }

        var projected = state
        var changes: [MemoryFactEvent] = []
        for candidate in candidates {
            guard MemoryEvidence.supports(candidate, in: observations) else { continue }
            guard
                let event = policy.decide(
                    candidate: candidate,
                    against: projected.currentFacts(),
                    factID: MemoryFactID()
                ).factEvent
            else { continue }
            projected.applyFactEvent(event)
            changes.append(event)
        }

        // A successfully generated report completes the captured batch even
        // when it proposes no acceptable fact. Failed model calls never reach
        // this decision and remain retryable.
        return .commit(
            MemoryExtractionCommit(
                generation: input.generation,
                processedSources: input.observations.map(\.sourceID),
                observations: input.observations,
                changes: changes
            )
        )
    }
}

/// Pure policy for turning an extractor's candidate into a memory transition. A fact is known by
/// its path: the same value again changes nothing, and another value at the same path replaces it.
///
/// The policy deliberately does not create IDs or write to a journal. The
/// caller supplies the candidate fact ID, which keeps this decision
/// deterministic and easy to test.
public struct MemoryPolicy: Equatable, Sendable {
    public let minimumConfidence: Double

    public init(minimumConfidence: Double = 0.7) {
        self.minimumConfidence = min(max(minimumConfidence, 0), 1)
    }

    public func decide(
        candidate: FactCandidate,
        against facts: [MemoryFact],
        factID: MemoryFactID
    ) -> MemoryDecision {
        guard candidate.confidence >= minimumConfidence, !candidate.evidence.isEmpty else {
            return .rejected
        }
        let fact = MemoryFact(
            id: factID,
            path: candidate.path,
            value: candidate.value,
            evidence: candidate.evidence,
            confidence: candidate.confidence,
            observedAt: candidate.observedAt
        )
        guard let existing = facts.first(where: { $0.status == .active && $0.path == candidate.path }) else {
            return .accepted(fact)
        }
        // Repeating it doesn't change memory: evidence is provenance, not a reason to write again.
        guard Self.compared(existing.value) != Self.compared(candidate.value) else { return .rejected }
        return .superseded(oldFactID: existing.id, replacement: fact)
    }

    /// A value as it's compared: its case and its spaces aside.
    private static func compared(_ value: String) -> String {
        value.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
