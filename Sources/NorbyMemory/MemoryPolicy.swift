import Foundation

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
            let matching = facts.enumerated().filter {
                $0.element.status == .active
                    && $0.element.namespace == candidate.namespace
                    && $0.element.predicate == candidate.predicate
            }

            guard let existing = matching
                .filter({ $0.element.value == candidate.value })
                .max(by: { left, right in
                if left.element.observedAt != right.element.observedAt {
                    return left.element.observedAt < right.element.observedAt
                }
                return left.offset < right.offset
            })?.element else {
                return .accepted(makeFact(from: candidate, id: factID))
            }

            return .reinforced(
                factID: existing.id,
                evidence: candidate.evidence,
                confidence: max(existing.confidence, candidate.confidence)
            )

        case .revise(let targetID, _):
            guard let existing = facts.first(where: {
                $0.id == targetID && $0.status == .active
            }) else {
                return .rejected
            }
            guard candidate.namespace == existing.namespace,
                  candidate.predicate == existing.predicate,
                  candidate.observedAt >= existing.observedAt
            else {
                return .rejected
            }

            if existing.value == candidate.value {
                return .reinforced(
                    factID: existing.id,
                    evidence: candidate.evidence,
                    confidence: max(existing.confidence, candidate.confidence)
                )
            }

            // An explicit revision identifies the fact being corrected. Its
            // confidence is still validated above, but it does not compete
            // with the old fact's confidence a second time.
            return .superseded(
                oldFactID: existing.id,
                replacement: makeFact(from: candidate, id: factID)
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
}
