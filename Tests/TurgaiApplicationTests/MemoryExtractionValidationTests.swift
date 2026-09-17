import Foundation
import Testing
import TurgaiDomain
import TurgaiMemory

@testable import TurgaiApplication

/// The Conversation-side candidate validation: a model candidate becomes a
/// concrete proposal only when it is grounded in exactly one durable
/// observation and every field parses.
struct MemoryExtractionValidationTests {
    private let observedAt = Date(timeIntervalSince1970: 1_700_000_000)

    private func observation(_ text: String, id: String = "00000000-0000-0000-0000-000000000001") -> MemoryObservation {
        MemoryObservation(
            id: ObservationID(rawValue: UUID(uuidString: id) ?? UUID()),
            sourceID: MemorySourceID(rawValue: UUID(uuidString: id) ?? UUID()),
            text: text,
            observedAt: observedAt
        )
    }

    private func candidate(
        supportingText: String = "I drink coffee every morning",
        namespace: String = "preference",
        predicate: String = "drinksCoffee",
        value: String = "true",
        valueKind: String = "preference"
    ) -> MemoryExtractionReport.MemoryExtractionCandidate {
        MemoryExtractionReport.MemoryExtractionCandidate(
            namespace: namespace,
            predicate: predicate,
            value: value,
            valueKind: valueKind,
            confidence: 0.9,
            importance: 0.8,
            stability: "stable",
            supportingText: supportingText
        )
    }

    @Test("a candidate grounded in exactly one observation becomes an add proposal")
    func validCandidateBecomesProposal() throws {
        let evidence = [observation("I drink coffee every morning before work")]
        let proposal = MemoryExtractionService.proposal(
            from: candidate(),
            evidence: evidence,
            observedAt: observedAt
        )
        guard case .add(let fact) = proposal else {
            Issue.record("Expected an add proposal, got \(String(describing: proposal))")
            return
        }
        #expect(fact.namespace == .preference)
        #expect(fact.predicate == "drinksCoffee")
        #expect(fact.value == .preference(true))
        #expect(fact.evidence == [evidence[0].id])
    }

    @Test("a quote matching nothing is rejected")
    func unmatchedQuoteIsRejected() {
        let proposal = MemoryExtractionService.proposal(
            from: candidate(),
            evidence: [observation("something else entirely")],
            observedAt: observedAt
        )
        #expect(proposal == nil)
    }

    @Test("a quote matching two observations is rejected, not guessed")
    func ambiguousQuoteIsRejected() {
        let evidence = [
            observation("I drink coffee every morning", id: "00000000-0000-0000-0000-000000000001"),
            observation("I drink coffee every morning, always", id: "00000000-0000-0000-0000-000000000002"),
        ]
        let proposal = MemoryExtractionService.proposal(
            from: candidate(),
            evidence: evidence,
            observedAt: observedAt
        )
        #expect(proposal == nil)
    }

    @Test("an unparseable namespace is rejected")
    func unknownNamespaceIsRejected() {
        let proposal = MemoryExtractionService.proposal(
            from: candidate(namespace: "not-a-namespace"),
            evidence: [observation("I drink coffee every morning")],
            observedAt: observedAt
        )
        #expect(proposal == nil)
    }

    @Test("an invalid typed value is rejected")
    func invalidTypedValueIsRejected() {
        let proposal = MemoryExtractionService.proposal(
            from: candidate(value: "not-a-date", valueKind: "date"),
            evidence: [observation("I drink coffee every morning")],
            observedAt: observedAt
        )
        #expect(proposal == nil)
    }
}
