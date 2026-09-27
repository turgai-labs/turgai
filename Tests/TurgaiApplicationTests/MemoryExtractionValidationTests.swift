import Foundation
import Testing
import TurgaiDomain
import TurgaiMemory

@testable import TurgaiApplication

/// The Conversation-side candidate validation: a model candidate becomes a
/// concrete proposal only when it is grounded in exactly one durable
/// observation and every field parses.
struct MemoryExtractionValidationTests {
    @Test("short answers retain the assistant question while evidence remains user-owned")
    func exchangeContext() throws {
        let question = MemoryObservation(
            sourceID: MemorySourceID(), text: "Weather please",
            response: "Which location?", observedAt: Date())
        let answer = observation("Haar, Germany")
        let transcript = MemoryExtractionService.transcript([question, answer])
        #expect(transcript == "user [1]: Weather please\nassistant [1]: Which location?\nuser [2]: Haar, Germany")
        let proposal = MemoryExtractionService.proposal(
            from: candidate(
                supportingText: "Haar, Germany", namespace: "environment",
                predicate: "weatherLocation", value: "Haar, Germany", valueKind: "place"),
            evidence: [question, answer])
        let accepted = try #require(proposal)
        guard case .add(let fact) = accepted else { return }
        #expect(MemoryEvidence.supports(fact, in: [question, answer]))
        #expect(fact.evidence == [answer.id])
        var memory = MemoryProjection()
        memory.apply(.observationRecorded(question))
        memory.apply(.observationRecorded(answer))
        let input = ExtractionInput(observations: [question, answer], generation: memory.generation, existingFacts: [])
        guard case .commit(let commit) = MemoryExtraction.decide(state: memory, input: input, proposals: [accepted])
        else {
            Issue.record("Expected the grounded location to be committed")
            return
        }
        memory.apply(.extractionCommitted(commit))
        #expect(memory.currentFacts().first?.value == .place("Haar, Germany"))
        memory.apply(.cleared(at: Date()))
        #expect(MemoryExtraction.decide(state: memory, input: input, proposals: [accepted]) == .stale)
        #expect(
            MemoryExtractionService.proposal(
                from: candidate(supportingText: "Which location?"), evidence: [question, answer]) == nil)
    }

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
            evidence: evidence
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

    @Test("repeated evidence entries do not make one observation ambiguous")
    func repeatedEvidenceStillHasOneSource() throws {
        let source = observation("I drink coffee every morning before work")
        let proposal = MemoryExtractionService.proposal(
            from: candidate(),
            evidence: [source, source]
        )
        guard case .add(let fact) = proposal else {
            Issue.record("Expected an add proposal, got \(String(describing: proposal))")
            return
        }
        #expect(fact.evidence == [source.id])
    }

    @Test("a quote matching nothing is rejected")
    func unmatchedQuoteIsRejected() {
        let proposal = MemoryExtractionService.proposal(
            from: candidate(),
            evidence: [observation("something else entirely")]
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
            evidence: evidence
        )
        #expect(proposal == nil)
    }

    @Test("an unparseable namespace is rejected")
    func unknownNamespaceIsRejected() {
        let proposal = MemoryExtractionService.proposal(
            from: candidate(namespace: "not-a-namespace"),
            evidence: [observation("I drink coffee every morning")]
        )
        #expect(proposal == nil)
    }

    @Test("an invalid typed value is rejected")
    func invalidTypedValueIsRejected() {
        let proposal = MemoryExtractionService.proposal(
            from: candidate(value: "not-a-date", valueKind: "date"),
            evidence: [observation("I drink coffee every morning")]
        )
        #expect(proposal == nil)
    }
}
