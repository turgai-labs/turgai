import Foundation
import Testing
import TurgaiDomain
import TurgaiMemory

@testable import TurgaiApplication

/// The Conversation-side candidate validation: a model candidate becomes a
/// concrete one only when it is grounded in exactly one durable
/// observation, its path is one, and its value is written.
struct MemoryExtractionValidationTests {
    @Test("short answers retain the assistant question while evidence remains user-owned")
    func exchangeContext() throws {
        let question = MemoryObservation(
            sourceID: MemorySourceID(), text: "Weather please",
            response: "Which location?", observedAt: Date())
        let answer = observation("Haar, Germany")
        let transcript = MemoryExtractionService.transcript([question, answer])
        #expect(transcript == "user [1]: Weather please\nassistant [1]: Which location?\nuser [2]: Haar, Germany")
        let fact = try #require(
            MemoryExtractionService.candidate(
                from: candidate(quote: "Haar, Germany", path: ["lives in"], value: "Haar, Germany"),
                evidence: [question, answer]))
        #expect(MemoryEvidence.supports(fact, in: [question, answer]))
        #expect(fact.evidence == [answer.id])
        var memory = Memory()
        memory.apply(.observationRecorded(question))
        memory.apply(.observationRecorded(answer))
        let input = ExtractionInput(observations: [question, answer], generation: memory.generation, existingFacts: [])
        guard case .commit(let commit) = MemoryExtraction.decide(state: memory, input: input, candidates: [fact])
        else {
            Issue.record("Expected the grounded location to be committed")
            return
        }
        memory.apply(.extractionCommitted(commit))
        #expect(memory.currentFacts().first?.value == "Haar, Germany")
        memory.apply(.cleared(at: Date()))
        #expect(MemoryExtraction.decide(state: memory, input: input, candidates: [fact]) == .stale)
        #expect(
            MemoryExtractionService.candidate(from: candidate(quote: "Which location?"), evidence: [question, answer])
                == nil)
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
        quote: String = "I drink coffee every morning",
        path: [String] = ["drinks", "coffee"],
        value: String = "every morning"
    ) -> MemoryExtractionReport.MemoryExtractionCandidate {
        MemoryExtractionReport.MemoryExtractionCandidate(path: path, value: value, quote: quote, confidence: 0.9)
    }

    @Test("a candidate grounded in exactly one observation becomes a fact candidate at its path")
    func validCandidateBecomesAFactCandidate() throws {
        let evidence = [observation("I drink coffee every morning before work")]
        let fact = try #require(MemoryExtractionService.candidate(from: candidate(), evidence: evidence))
        #expect(fact.path == MemoryPath(["drinks", "coffee"]))
        #expect(fact.value == "every morning")
        #expect(fact.evidence == [evidence[0].id])
    }

    @Test("repeated evidence entries do not make one observation ambiguous")
    func repeatedEvidenceStillHasOneSource() throws {
        let source = observation("I drink coffee every morning before work")
        let fact = try #require(MemoryExtractionService.candidate(from: candidate(), evidence: [source, source]))
        #expect(fact.evidence == [source.id])
    }

    @Test("a quote matching nothing is rejected")
    func unmatchedQuoteIsRejected() {
        #expect(
            MemoryExtractionService.candidate(from: candidate(), evidence: [observation("something else entirely")])
                == nil)
    }

    @Test("a quote matching two observations is rejected, not guessed")
    func ambiguousQuoteIsRejected() {
        let evidence = [
            observation("I drink coffee every morning", id: "00000000-0000-0000-0000-000000000001"),
            observation("I drink coffee every morning, always", id: "00000000-0000-0000-0000-000000000002"),
        ]
        #expect(MemoryExtractionService.candidate(from: candidate(), evidence: evidence) == nil)
    }

    @Test("a path that isn't one, or a value that's empty, is rejected")
    func pathAndValueMustBeWritten() {
        let evidence = [observation("I drink coffee every morning")]
        #expect(MemoryExtractionService.candidate(from: candidate(path: []), evidence: evidence) == nil)
        #expect(MemoryExtractionService.candidate(from: candidate(path: ["a", "b", "c", "d"]), evidence: evidence) == nil)
        #expect(MemoryExtractionService.candidate(from: candidate(value: " "), evidence: evidence) == nil)
    }
}
