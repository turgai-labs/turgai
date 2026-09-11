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
        state: MemoryProjection,
        input: ExtractionInput,
        proposals: [MemoryProposal],
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
        for proposal in proposals {
            let candidate: FactCandidate
            switch proposal {
            case .add(let value), .revise(_, let value):
                candidate = value
            }
            guard MemoryEvidence.supports(candidate, in: observations) else { continue }
            guard
                let event = policy.decide(
                    proposal: proposal,
                    against: projected.currentFacts(),
                    factID: MemoryFactID()
                ).factEvent
            else { continue }
            projected.applyFactEvent(event)
            changes.append(event)
        }

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

/// Pure policy for turning an extractor proposal into a memory transition.
///
/// The policy deliberately does not create IDs or write to a journal. The
/// caller supplies the candidate fact ID, which keeps this decision
/// deterministic and easy to test.
public struct MemoryPolicy: Equatable, Sendable {
    public let minimumConfidence: Double
    public let minimumImportance: Double

    public init(
        minimumConfidence: Double = 0.7,
        minimumImportance: Double = 0.2
    ) {
        self.minimumConfidence = min(max(minimumConfidence, 0), 1)
        self.minimumImportance = min(max(minimumImportance, 0), 1)
    }

    public func decide(
        candidate: FactCandidate,
        against facts: [MemoryFact],
        factID: MemoryFactID
    ) -> MemoryDecision {
        decide(
            proposal: .add(candidate),
            against: facts,
            factID: factID
        )
    }

    public func decide(
        proposal: MemoryProposal,
        against facts: [MemoryFact],
        factID: MemoryFactID
    ) -> MemoryDecision {
        let candidate: FactCandidate
        switch proposal {
        case .add(let value), .revise(_, let value):
            candidate = value
        }

        guard candidate.confidence >= minimumConfidence,
            candidate.importance >= minimumImportance,
            !candidate.evidence.isEmpty
        else {
            return .rejected
        }

        // Transient context is allowed only when the extractor gives it an
        // explicit expiry. This prevents ordinary one-off activity becoming
        // durable personal memory by accident.
        if candidate.stability == .transient, candidate.validUntil == nil {
            return .rejected
        }

        switch proposal {
        case .add:
            guard
                !facts.contains(where: {
                    $0.status == .active
                        && $0.namespace == candidate.namespace
                        && $0.predicate == candidate.predicate
                        && $0.value == candidate.value
                })
            else {
                // Repeating an equivalent claim does not change memory.
                // Evidence is provenance, not a reason to mutate the fact on
                // every turn.
                return .rejected
            }

            return .accepted(makeFact(from: candidate, id: factID))

        case .revise(let targetID, _):
            guard
                let existing = facts.first(where: {
                    $0.id == targetID && $0.status == .active
                })
            else {
                return .rejected
            }
            guard candidate.observedAt >= existing.observedAt
            else {
                return .rejected
            }

            if existing.value == candidate.value {
                return .rejected
            }

            // An explicit revision identifies the fact being corrected. Its
            // confidence is still validated above, but it does not compete
            // with the old fact's confidence a second time.
            return .superseded(
                oldFactID: existing.id,
                replacement: makeFact(
                    from: candidate,
                    id: factID,
                    preserving: existing
                )
            )
        }
    }

    private func makeFact(from candidate: FactCandidate, id: MemoryFactID) -> MemoryFact {
        MemoryFact(
            id: id,
            namespace: candidate.namespace,
            predicate: candidate.predicate,
            value: candidate.value,
            evidence: candidate.evidence,
            confidence: candidate.confidence,
            importance: candidate.importance,
            stability: candidate.stability,
            observedAt: candidate.observedAt,
            validFrom: candidate.observedAt,
            validUntil: candidate.validUntil
        )
    }

    private func makeFact(
        from candidate: FactCandidate,
        id: MemoryFactID,
        preserving existing: MemoryFact
    ) -> MemoryFact {
        MemoryFact(
            id: id,
            namespace: existing.namespace,
            predicate: existing.predicate,
            value: candidate.value,
            evidence: candidate.evidence,
            confidence: candidate.confidence,
            importance: candidate.importance,
            stability: candidate.stability,
            observedAt: candidate.observedAt,
            validFrom: candidate.observedAt,
            validUntil: candidate.validUntil
        )
    }
}
