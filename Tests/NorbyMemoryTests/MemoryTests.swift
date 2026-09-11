import NorbyMemory
import Testing

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

struct MemoryTests {
    private let sourceID = MemorySourceID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
    private let observationID = ObservationID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
    private let factID = MemoryFactID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!)

    @Test
    func observationProjectionIsIdempotentAndBoundedBySourceMessage() {
        let observation = MemoryObservation(
            id: observationID,
            sourceID: sourceID,
            text: "Berlin",
            observedAt: Date(timeIntervalSince1970: 1)
        )
        var projection = MemoryProjection()

        projection.apply(.observationRecorded(observation))
        projection.apply(.observationRecorded(observation))

        #expect(projection.observations == [observation])
        #expect(projection.containsObservation(for: sourceID))
    }

    @Test
    func extractionDecisionCommitsTheBatchAndRecognizesRepeatedCommit() {
        let observation = MemoryObservation(
            id: observationID,
            sourceID: sourceID,
            text: "I live in Haar",
            observedAt: Date(timeIntervalSince1970: 1)
        )
        let input = ExtractionInput(
            observations: [observation],
            generation: .initial,
            existingFacts: []
        )
        let candidate = FactCandidate(
            namespace: .environment,
            predicate: "lives_in",
            value: .place("Haar"),
            evidence: [observationID],
            supportingText: "I live in Haar",
            confidence: 1,
            importance: 1,
            stability: .mutable,
            observedAt: observation.observedAt
        )

        guard
            case .commit(let commit) = MemoryExtraction.decide(
                state: MemoryProjection(),
                input: input,
                proposals: [.add(candidate)]
            )
        else {
            Issue.record("expected a memory extraction commit")
            return
        }

        var projection = MemoryProjection()
        projection.apply(.extractionCommitted(commit))
        #expect(projection.containsObservation(for: sourceID))
        #expect(projection.currentFacts().count == 1)

        #expect(
            MemoryExtraction.decide(
                state: projection,
                input: input,
                proposals: [.add(candidate)]
            ) == .alreadyHandled
        )
    }

    @Test
    func rejectedCandidatesLeaveObservationsPending() {
        let observation = MemoryObservation(
            id: observationID,
            sourceID: sourceID,
            text: "My name is Ada",
            observedAt: Date(timeIntervalSince1970: 1)
        )
        let input = ExtractionInput(
            observations: [observation],
            generation: .initial,
            existingFacts: []
        )
        let candidate = FactCandidate(
            namespace: .profile,
            predicate: "name",
            value: .person("Ada"),
            evidence: [observationID],
            supportingText: "a quote that appears nowhere in the observation",
            confidence: 1,
            importance: 1,
            stability: .stable,
            observedAt: observation.observedAt
        )

        let decision = MemoryExtraction.decide(
            state: MemoryProjection(),
            input: input,
            proposals: [.add(candidate)]
        )

        #expect(decision == .alreadyHandled)
        var projection = MemoryProjection()
        projection.apply(.observationRecorded(observation))
        #expect(!projection.isProcessed(observation))
    }

    @Test
    func onlyObservationsSupportingAcceptedFactsAreConsumed() {
        let first = MemoryObservation(
            id: observationID,
            sourceID: sourceID,
            text: "I live in Haar",
            observedAt: Date(timeIntervalSince1970: 1)
        )
        let secondSourceID = MemorySourceID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!)
        let second = MemoryObservation(
            id: ObservationID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000005")!),
            sourceID: secondSourceID,
            text: "thanks",
            observedAt: Date(timeIntervalSince1970: 2)
        )
        let input = ExtractionInput(
            observations: [first, second],
            generation: .initial,
            existingFacts: []
        )
        let candidate = FactCandidate(
            namespace: .environment,
            predicate: "lives_in",
            value: .place("Haar"),
            evidence: [observationID],
            supportingText: "I live in Haar",
            confidence: 1,
            importance: 1,
            stability: .mutable,
            observedAt: first.observedAt
        )

        guard
            case .commit(let commit) = MemoryExtraction.decide(
                state: MemoryProjection(),
                input: input,
                proposals: [.add(candidate)]
            )
        else {
            Issue.record("expected a memory extraction commit")
            return
        }

        #expect(commit.processedSources == [sourceID])
        var projection = MemoryProjection()
        projection.apply(.extractionCommitted(commit))
        #expect(projection.isProcessed(first))
        #expect(!projection.isProcessed(second))
    }

    @Test
    func clearingMemoryStartsANewGenerationAndRemovesTheProjection() {
        let observation = MemoryObservation(
            id: observationID,
            sourceID: sourceID,
            text: "My name is Ada",
            observedAt: Date(timeIntervalSince1970: 1)
        )
        let fact = MemoryFact(
            id: factID,
            namespace: .profile,
            predicate: "name",
            value: .person("Ada"),
            evidence: [observationID],
            confidence: 1,
            importance: 1,
            stability: .stable,
            observedAt: observation.observedAt
        )
        var projection = MemoryProjection()
        projection.apply(.observationRecorded(observation))
        projection.apply(.factAccepted(fact))
        let generation = projection.generation

        projection.apply(.cleared(at: Date(timeIntervalSince1970: 2)))

        #expect(projection.observations.isEmpty)
        #expect(projection.facts.isEmpty)
        #expect(projection.generation == generation.advancing())
    }

    @Test
    func observationsFromBeforeForgetCannotEnterTheNewGeneration() {
        var projection = MemoryProjection()
        projection.apply(.cleared(at: Date(timeIntervalSince1970: 10)))

        #expect(
            !projection.accepts(
                MemoryObservation(
                    sourceID: sourceID,
                    text: "old",
                    observedAt: Date(timeIntervalSince1970: 9)
                )
            )
        )
        #expect(
            projection.accepts(
                MemoryObservation(
                    sourceID: sourceID,
                    text: "new",
                    observedAt: Date(timeIntervalSince1970: 11)
                )
            )
        )
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
            text: "Berlin",
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
    func extractionInputMergesCurrentAndPreviousObservationsChronologically() {
        let question = MemoryObservation(
            sourceID: MemorySourceID(rawValue: UUID()),
            text: "Where do you live?",
            response: "I don't know yet — where are you based?",
            observedAt: Date(timeIntervalSince1970: 1)
        )
        let correction = MemoryObservation(
            sourceID: MemorySourceID(rawValue: UUID()),
            text: "Sorry, I meant Haar.",
            response: "Thanks, I updated the location context.",
            observedAt: Date(timeIntervalSince1970: 2)
        )
        let answer = MemoryObservation(
            sourceID: MemorySourceID(rawValue: UUID()),
            text: "Haar, Landkreis München",
            response: "Got it.",
            observedAt: Date(timeIntervalSince1970: 3)
        )
        let followUp = MemoryObservation(
            sourceID: MemorySourceID(rawValue: UUID()),
            text: "Use that for weather and reminders.",
            response: "Understood.",
            observedAt: Date(timeIntervalSince1970: 4)
        )
        let input = ExtractionInput(
            observations: [followUp, answer],
            generation: .initial,
            existingFacts: [],
            previousObservations: [correction, question]
        )

        #expect(
            input.chronologicalObservations.map(\.id) == [
                question.id,
                correction.id,
                answer.id,
                followUp.id,
            ])
    }

    @Test
    func policyAcceptsAndSupersedesFactsWithoutReinforcingRepeats() {
        let candidate = FactCandidate(
            namespace: .profile,
            predicate: "home",
            value: .place("Berlin"),
            evidence: [observationID],
            supportingText: "Berlin",
            confidence: 0.95,
            importance: 0.9,
            stability: .mutable
        )
        let policy = MemoryPolicy()

        guard
            case .accepted(let fact) = policy.decide(
                candidate: candidate,
                against: [],
                factID: factID
            )
        else {
            Issue.record("Expected the first candidate to be accepted")
            return
        }

        guard
            case .rejected = policy.decide(
                candidate: candidate,
                against: [fact],
                factID: MemoryFactID()
            )
        else {
            Issue.record("Expected the matching candidate to be a no-op")
            return
        }

        let replacement = FactCandidate(
            namespace: .profile,
            predicate: "home",
            value: .place("Munich"),
            evidence: [observationID],
            supportingText: "Munich",
            confidence: 0.99,
            importance: 0.9,
            stability: .mutable,
            validUntil: nil
        )
        guard
            case .superseded(let oldID, let newFact) = policy.decide(
                proposal: .revise(factID: factID, candidate: replacement),
                against: [fact],
                factID: MemoryFactID()
            )
        else {
            Issue.record("Expected the stronger contradictory candidate to supersede the fact")
            return
        }
        #expect(oldID == factID)
        #expect(newFact.value == .place("Munich"))

        let differentlyNamedRevision = FactCandidate(
            namespace: .profile,
            predicate: "lives_in",
            value: .place("London"),
            evidence: [observationID],
            supportingText: "London",
            confidence: 0.99,
            importance: 0.9,
            stability: .mutable
        )
        guard
            case .superseded(_, let canonicalFact) = policy.decide(
                proposal: .revise(factID: factID, candidate: differentlyNamedRevision),
                against: [fact],
                factID: MemoryFactID()
            )
        else {
            Issue.record("Expected an explicit revision to target the existing fact")
            return
        }
        #expect(canonicalFact.predicate == fact.predicate)
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
            supportingText: "London",
            confidence: 0.8,
            importance: 0.8,
            stability: .mutable,
            observedAt: Date(timeIntervalSince1970: 2)
        )

        guard
            case .accepted(let fact) = MemoryPolicy().decide(
                proposal: .add(london),
                against: [berlin],
                factID: MemoryFactID()
            )
        else {
            Issue.record("Expected a distinct addition to coexist with the old fact")
            return
        }
        #expect(fact.value == .place("London"))
    }

    @Test
    func additionOfAnOlderMatchingValueIsANoOpEvenWhenAnotherValueIsNewer() {
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
            supportingText: "I like Swift",
            confidence: 0.9,
            importance: 0.5,
            stability: .situational,
            observedAt: Date(timeIntervalSince1970: 3)
        )

        guard
            case .rejected = MemoryPolicy().decide(
                proposal: .add(repeated),
                against: [olderFact, newerFact],
                factID: MemoryFactID()
            )
        else {
            Issue.record("Expected the matching older value to be a no-op")
            return
        }
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
            supportingText: "Berlin",
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
    func retrievalOmitsUnrelatedFacts() {
        let home = MemoryFact(
            id: factID,
            namespace: .profile,
            predicate: "home",
            value: .place("Berlin"),
            evidence: [observationID],
            confidence: 0.95,
            importance: 1,
            stability: .mutable,
            observedAt: Date(timeIntervalSince1970: 1)
        )
        var projection = MemoryProjection()
        projection.apply(.factAccepted(home))

        let facts = MemoryRetrieval.facts(
            from: projection,
            matching: MemoryQuery(text: "test without tools", limit: 6),
            now: Date(timeIntervalSince1970: 2)
        )

        #expect(facts.isEmpty)
    }

    @Test
    func evidenceMustComeFromUserTextRatherThanAssistantResponse() {
        let observation = MemoryObservation(
            id: observationID,
            sourceID: sourceID,
            text: "Can you show me the weather in Haar?",
            response: "You live in Haar.",
            observedAt: Date(timeIntervalSince1970: 1)
        )
        let candidate = FactCandidate(
            namespace: .profile,
            predicate: "home",
            value: .place("Haar"),
            evidence: [observationID],
            supportingText: "You live in Haar",
            confidence: 0.95,
            importance: 0.9,
            stability: .mutable,
            observedAt: observation.observedAt
        )

        #expect(!MemoryEvidence.supports(candidate, in: [observation]))

        let userSupported = FactCandidate(
            namespace: .profile,
            predicate: "home",
            value: .place("Haar"),
            evidence: [observationID],
            supportingText: "weather in Haar",
            confidence: 0.95,
            importance: 0.9,
            stability: .mutable,
            observedAt: observation.observedAt
        )
        #expect(MemoryEvidence.supports(userSupported, in: [observation]))
    }

}
