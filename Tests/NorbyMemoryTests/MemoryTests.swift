import Foundation
import NorbyMemory
import Testing

struct MemoryTests {
    private let sourceID = MemorySourceID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
    private let observationID = ObservationID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
    private let factID = MemoryFactID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!)

    @Test
    func observationProjectionIsIdempotentAndBoundedBySourceMessage() {
        let observation = MemoryObservation(
            id: observationID,
            sourceID: sourceID,
            text: "I live in Berlin",
            observedAt: Date(timeIntervalSince1970: 1)
        )
        var projection = MemoryProjection()

        projection.apply(.observationRecorded(observation))
        projection.apply(.observationRecorded(observation))

        #expect(projection.observations == [observation])
        #expect(projection.containsObservation(for: sourceID))
    }

    @Test
    func memoryUpdateCountsChangesWithinTheUpdate() {
        let update = MemoryUpdate(
            factChanges: [.accepted, .reinforced, .superseded]
        )

        #expect(update.changedFactCount == 3)
        #expect(update.newFactCount == 1)
        #expect(update.updatedFactCount == 2)
        #expect(update.shouldNotify)
    }

    @Test
    func completedObservationEnrichesTheExistingSource() {
        let recorded = MemoryObservation(
            id: observationID,
            sourceID: sourceID,
            text: "My name is Ada",
            observedAt: Date(timeIntervalSince1970: 1)
        )
        var projection = MemoryProjection()
        projection.apply(.observationRecorded(recorded))
        projection.apply(
            .observationCompleted(
                sourceID: sourceID,
                response: "Nice to meet you."
            )
        )
        projection.apply(
            .observationCompleted(
                sourceID: sourceID,
                response: "A different response"
            )
        )

        #expect(
            projection.observations == [
                MemoryObservation(
                    id: observationID,
                    sourceID: sourceID,
                    text: "My name is Ada",
                    response: "Nice to meet you.",
                    observedAt: Date(timeIntervalSince1970: 1)
                )
            ]
        )
    }

    @Test
    func previousObservationsFollowJournalOrder() {
        let first = MemoryObservation(
            sourceID: MemorySourceID(rawValue: UUID()),
            text: "Where do you live?",
            observedAt: Date(timeIntervalSince1970: 1)
        )
        let second = MemoryObservation(
            sourceID: MemorySourceID(rawValue: UUID()),
            text: "I live in Berlin.",
            observedAt: Date(timeIntervalSince1970: 2)
        )
        let third = MemoryObservation(
            sourceID: MemorySourceID(rawValue: UUID()),
            text: "I moved to London.",
            observedAt: Date(timeIntervalSince1970: 3)
        )
        var projection = MemoryProjection()
        projection.apply(.observationRecorded(first))
        projection.apply(.observationRecorded(second))
        projection.apply(.observationRecorded(third))

        #expect(
            projection
                .previousObservations(before: third.sourceID, limit: 2)
                .map(\.id) == [first.id, second.id]
        )
        #expect(
            projection
                .previousObservations(before: second.sourceID, limit: 2)
                .map(\.id) == [first.id]
        )
    }

    @Test
    func policyAcceptsReinforcesAndSupersedesFacts() {
        let candidate = FactCandidate(
            namespace: .profile,
            predicate: "home",
            value: .place("Berlin"),
            evidence: [observationID],
            confidence: 0.95,
            importance: 0.9,
            stability: .mutable
        )
        let policy = MemoryPolicy()

        guard case .accepted(let fact) = policy.decide(
            candidate: candidate,
            against: [],
            factID: factID
        ) else {
            Issue.record("Expected the first candidate to be accepted")
            return
        }

        guard case .reinforced(let reinforcedID, _, let confidence) = policy.decide(
            candidate: candidate,
            against: [fact],
            factID: MemoryFactID()
        ) else {
            Issue.record("Expected the matching candidate to reinforce the fact")
            return
        }
        #expect(reinforcedID == factID)
        #expect(confidence == 0.95)

        let replacement = FactCandidate(
            namespace: .profile,
            predicate: "home",
            value: .place("Munich"),
            evidence: [observationID],
            confidence: 0.99,
            importance: 0.9,
            stability: .mutable,
            validUntil: nil
        )
        guard case .superseded(let oldID, let newFact) = policy.decide(
            proposal: .revise(factID: factID, candidate: replacement),
            against: [fact],
            factID: MemoryFactID()
        ) else {
            Issue.record("Expected the stronger contradictory candidate to supersede the fact")
            return
        }
        #expect(oldID == factID)
        #expect(newFact.value == .place("Munich"))
    }

    @Test
    func additionsDoNotReplaceDifferentFactsWithTheSamePredicate() {
        let berlin = MemoryFact(
            id: factID,
            namespace: .profile,
            predicate: "home",
            value: .place("Berlin"),
            evidence: [observationID],
            confidence: 0.95,
            importance: 0.9,
            stability: .mutable,
            observedAt: Date(timeIntervalSince1970: 1)
        )
        let londonObservation = ObservationID(rawValue: UUID())
        let london = FactCandidate(
            namespace: .profile,
            predicate: "home",
            value: .place("London"),
            evidence: [londonObservation],
            confidence: 0.8,
            importance: 0.8,
            stability: .mutable,
            observedAt: Date(timeIntervalSince1970: 2)
        )

        guard case .accepted(let fact) = MemoryPolicy().decide(
            proposal: .add(london),
            against: [berlin],
            factID: MemoryFactID()
        ) else {
            Issue.record("Expected a distinct addition to coexist with the old fact")
            return
        }
        #expect(fact.value == .place("London"))
    }

    @Test
    func additionReinforcesAnOlderMatchingValueEvenWhenAnotherValueIsNewer() {
        let olderObservation = ObservationID(rawValue: UUID())
        let newerObservation = ObservationID(rawValue: UUID())
        let olderFact = MemoryFact(
            id: factID,
            namespace: .preference,
            predicate: "likes",
            value: .text("Swift"),
            evidence: [olderObservation],
            confidence: 0.8,
            importance: 0.5,
            stability: .situational,
            observedAt: Date(timeIntervalSince1970: 1)
        )
        let newerFact = MemoryFact(
            namespace: .preference,
            predicate: "likes",
            value: .text("Elixir"),
            evidence: [newerObservation],
            confidence: 0.8,
            importance: 0.5,
            stability: .situational,
            observedAt: Date(timeIntervalSince1970: 2)
        )
        let repeated = FactCandidate(
            namespace: .preference,
            predicate: "likes",
            value: .text("Swift"),
            evidence: [observationID],
            confidence: 0.9,
            importance: 0.5,
            stability: .situational,
            observedAt: Date(timeIntervalSince1970: 3)
        )

        guard case .reinforced(let reinforcedID, _, _) = MemoryPolicy().decide(
            proposal: .add(repeated),
            against: [olderFact, newerFact],
            factID: MemoryFactID()
        ) else {
            Issue.record("Expected the matching older value to be reinforced")
            return
        }
        #expect(reinforcedID == factID)
    }

    @Test
    func staleRevisionIsRejected() {
        let current = MemoryFact(
            id: factID,
            namespace: .profile,
            predicate: "home",
            value: .place("London"),
            evidence: [observationID],
            confidence: 0.8,
            importance: 0.8,
            stability: .mutable,
            observedAt: Date(timeIntervalSince1970: 2)
        )
        let stale = FactCandidate(
            namespace: .profile,
            predicate: "home",
            value: .place("Berlin"),
            evidence: [ObservationID(rawValue: UUID())],
            confidence: 1,
            importance: 1,
            stability: .mutable,
            observedAt: Date(timeIntervalSince1970: 1)
        )

        let decision = MemoryPolicy().decide(
            proposal: .revise(factID: factID, candidate: stale),
            against: [current],
            factID: MemoryFactID()
        )
        #expect(decision == .rejected)
    }

    @Test
    func retrievalUsesLexicalRelevanceAndRendersUntrustedContext() {
        let berlin = MemoryFact(
            id: factID,
            namespace: .profile,
            predicate: "home",
            value: .place("Berlin"),
            evidence: [observationID],
            confidence: 0.95,
            importance: 0.9,
            stability: .mutable,
            observedAt: Date(timeIntervalSince1970: 1)
        )
        var projection = MemoryProjection()
        projection.apply(.factAccepted(berlin))

        let facts = MemoryRetrieval.facts(
            from: projection,
            matching: MemoryQuery(text: "where is my home?", limit: 1),
            now: Date(timeIntervalSince1970: 2)
        )
        #expect(facts == [berlin])
        #expect(MemoryRetrieval.systemInstruction(for: facts)?.contains("untrusted") == true)
    }

    @Test
    func extractorProposesFactsFromCompletedObservation() {
        let observation = MemoryObservation(
            id: observationID,
            sourceID: sourceID,
            text: "My name is Ada",
            response: "Nice to meet you.",
            observedAt: Date(timeIntervalSince1970: 1)
        )

        let candidates = MemoryExtractor.extract(from: observation)

        #expect(candidates.count == 1)
        #expect(candidates[0].predicate == "name")
        #expect(candidates[0].value == .person("Ada"))
        #expect(candidates[0].evidence == [observationID])
    }

}
