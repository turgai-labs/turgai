import Testing
import TurgaiMemory

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
        var projection = Memory()

        projection.apply(.observationRecorded(observation))
        projection.apply(.observationRecorded(observation))

        #expect(projection.observations == [observation])
        #expect(projection.containsObservation(for: sourceID))
    }

    @Test
    func latestExtractionTriggerUsesJournalOrderWhenTurnsFinishOutOfOrder() {
        let laterMessage = MemoryObservation(
            sourceID: sourceID,
            text: "sent later, completed first",
            observedAt: Date(timeIntervalSince1970: 2)
        )
        let earlierMessage = MemoryObservation(
            sourceID: MemorySourceID(),
            text: "sent earlier, completed later",
            observedAt: Date(timeIntervalSince1970: 1)
        )
        var projection = Memory()
        projection.apply(.observationRecorded(laterMessage))
        projection.apply(.observationRecorded(earlierMessage))

        #expect(projection.latestObservationSourceID == earlierMessage.sourceID)
    }

    @Test
    func observationTailDropsOldestObservationsBeyondTheCap() {
        var projection = Memory()
        let first = MemoryObservation(
            sourceID: sourceID,
            text: "first",
            observedAt: Date(timeIntervalSince1970: 1)
        )
        projection.apply(.observationRecorded(first))

        for index in 2...(Memory.maximumObservations + 1) {
            projection.apply(
                .observationRecorded(
                    MemoryObservation(
                        sourceID: MemorySourceID(),
                        text: "message \(index)",
                        observedAt: Date(timeIntervalSince1970: TimeInterval(index))
                    )
                )
            )
        }

        #expect(projection.observations.count == Memory.maximumObservations)
        #expect(!projection.containsObservation(for: sourceID))
        #expect(
            projection.recentObservations(limit: 1).first?.text
                == "message \(Memory.maximumObservations + 1)"
        )
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
            path: MemoryPath(["lives_in"])!,
            value: "Haar",
            evidence: [observationID],
            supportingText: "I live in Haar",
            confidence: 1,
            observedAt: observation.observedAt
        )

        guard
            case .commit(let commit) = MemoryExtraction.decide(
                state: Memory(),
                input: input,
                candidates: [candidate]
            )
        else {
            Issue.record("expected a memory extraction commit")
            return
        }

        var projection = Memory()
        projection.apply(.extractionCommitted(commit))
        #expect(projection.containsObservation(for: sourceID))
        #expect(projection.currentFacts().count == 1)

        #expect(
            MemoryExtraction.decide(
                state: projection,
                input: input,
                candidates: [candidate]
            ) == .alreadyHandled
        )
    }

    @Test
    func rejectedCandidatesCompleteTheProcessedBatch() {
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
            path: MemoryPath(["name"])!,
            value: "Ada",
            evidence: [observationID],
            supportingText: "a quote that appears nowhere in the observation",
            confidence: 1,
            observedAt: observation.observedAt
        )

        let decision = MemoryExtraction.decide(
            state: Memory(),
            input: input,
            candidates: [candidate]
        )

        guard case .commit(let commit) = decision else {
            Issue.record("Expected the examined batch to be committed without facts")
            return
        }
        var projection = Memory()
        projection.apply(.observationRecorded(observation))
        projection.apply(.extractionCommitted(commit))
        #expect(projection.isProcessed(observation))
    }

    @Test
    func successfulExtractionCompletesEveryObservationInTheBatch() {
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
            path: MemoryPath(["lives_in"])!,
            value: "Haar",
            evidence: [observationID],
            supportingText: "I live in Haar",
            confidence: 1,
            observedAt: first.observedAt
        )

        guard
            case .commit(let commit) = MemoryExtraction.decide(
                state: Memory(),
                input: input,
                candidates: [candidate]
            )
        else {
            Issue.record("expected a memory extraction commit")
            return
        }

        #expect(commit.processedSources == [sourceID, secondSourceID])
        var projection = Memory()
        projection.apply(.extractionCommitted(commit))
        #expect(projection.isProcessed(first))
        #expect(projection.isProcessed(second))
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
            path: MemoryPath(["name"])!,
            value: "Ada",
            evidence: [observationID],
            confidence: 1,
            observedAt: observation.observedAt
        )
        var projection = Memory()
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
        var projection = Memory()
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

    /// Whether a person is remembered is theirs to change, and forgetting what's remembered keeps it.
    @Test
    func rememberingIsKeptThroughForgettingAndAsData() throws {
        var memory = Memory()
        #expect(memory.remembering == .on)
        memory.apply(.rememberingChanged(.off))
        memory.apply(.cleared(at: Date(timeIntervalSince1970: 10)))
        #expect(memory.remembering == .off)
        let decoded = try JSONDecoder().decode(Memory.self, from: try JSONEncoder().encode(memory))
        #expect(decoded.remembering == .off)
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
        var projection = Memory()
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
            path: MemoryPath(["home"])!,
            value: "Berlin",
            evidence: [observationID],
            supportingText: "Berlin",
            confidence: 0.95,
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
            path: MemoryPath(["home"])!,
            value: "Munich",
            evidence: [observationID],
            supportingText: "Munich",
            confidence: 0.99,
        )
        guard
            case .superseded(let oldID, let newFact) = policy.decide(
                candidate: replacement,
                against: [fact],
                factID: MemoryFactID()
            )
        else {
            Issue.record("Expected the stronger contradictory candidate to supersede the fact")
            return
        }
        #expect(oldID == factID)
        #expect(newFact.value == "Munich")

        // The same name, written another way, is the same path.
        #expect(MemoryPath(["Home "]) == fact.path)
    }

    @Test
    func additionsSupersedeContradictionsAndLeaveOtherFactsAlone() {
        let berlin = MemoryFact(
            id: factID,
            path: MemoryPath(["home"])!,
            value: "Berlin",
            evidence: [observationID],
            confidence: 0.95,
            observedAt: Date(timeIntervalSince1970: 1)
        )
        let policy = MemoryPolicy()

        // The same path and value: repeating an equivalent
        // claim does not change memory.
        let equivalent = FactCandidate(
            path: MemoryPath(["home"])!,
            value: "Berlin",
            evidence: [observationID],
            supportingText: "Berlin",
            confidence: 0.95,
            observedAt: Date(timeIntervalSince1970: 2)
        )
        #expect(
            policy.decide(
                candidate: equivalent,
                against: [berlin],
                factID: MemoryFactID()
            ) == .rejected
        )

        // The same path, a different value: the contradiction
        // is resolved in policy — the incoming claim supersedes the active
        // fact, and the old fact is no longer active.
        let london = FactCandidate(
            path: MemoryPath(["home"])!,
            value: "London",
            evidence: [ObservationID(rawValue: UUID())],
            supportingText: "London",
            confidence: 0.8,
            observedAt: Date(timeIntervalSince1970: 2)
        )
        guard
            case .superseded(let oldID, let replacement) = policy.decide(
                candidate: london,
                against: [berlin],
                factID: MemoryFactID()
            )
        else {
            Issue.record("Expected the contradictory addition to supersede the active fact")
            return
        }
        #expect(oldID == factID)
        #expect(replacement.value == "London")

        var projection = Memory()
        projection.apply(.factAccepted(berlin))
        projection.apply(.factSuperseded(oldID, by: replacement))
        #expect(projection.currentFacts().count == 1)
        #expect(projection.currentFacts().first { $0.path == MemoryPath(["home"]) }?.value == "London")

        // A different path is an independent second fact.
        let employer = FactCandidate(
            path: MemoryPath(["employer"])!,
            value: "Acme",
            evidence: [ObservationID(rawValue: UUID())],
            supportingText: "Acme",
            confidence: 0.8,
            observedAt: Date(timeIntervalSince1970: 3)
        )
        guard
            case .accepted(let second) = policy.decide(
                candidate: employer,
                against: projection.currentFacts(),
                factID: MemoryFactID()
            )
        else {
            Issue.record("Expected the different-path addition to be accepted")
            return
        }
        #expect(second.path == MemoryPath(["employer"]))
    }

    @Test
    func additionOfAnOlderMatchingValueIsANoOpEvenWhenAnotherValueIsNewer() {
        let olderObservation = ObservationID(rawValue: UUID())
        let newerObservation = ObservationID(rawValue: UUID())
        let olderFact = MemoryFact(
            id: factID,
            path: MemoryPath(["likes"])!,
            value: "Swift",
            evidence: [olderObservation],
            confidence: 0.8,
            observedAt: Date(timeIntervalSince1970: 1)
        )
        let newerFact = MemoryFact(
            path: MemoryPath(["likes"])!,
            value: "Elixir",
            evidence: [newerObservation],
            confidence: 0.8,
            observedAt: Date(timeIntervalSince1970: 2)
        )
        let repeated = FactCandidate(
            path: MemoryPath(["likes"])!,
            value: "Swift",
            evidence: [observationID],
            supportingText: "I like Swift",
            confidence: 0.9,
            observedAt: Date(timeIntervalSince1970: 3)
        )

        guard
            case .rejected = MemoryPolicy().decide(
                candidate: repeated,
                against: [olderFact, newerFact],
                factID: MemoryFactID()
            )
        else {
            Issue.record("Expected the matching older value to be a no-op")
            return
        }
    }

    /// What's remembered is a tree: names a path shares are one node, each fact sits at its path's
    /// last name, and a recall gives it as data that can be out of date.
    @Test
    func whatsRememberedIsATreeOfPaths() {
        func fact(_ path: [String], _ value: String) -> MemoryFact {
            MemoryFact(
                path: MemoryPath(path)!,
                value: value,
                evidence: [observationID],
                confidence: 0.9,
                observedAt: Date(timeIntervalSince1970: 1)
            )
        }
        var memory = Memory()
        for remembered in [
            fact(["lives in"], "Haar, Germany"), fact(["family", "sister"], "Ann"), fact(["Family", "brother"], "Bob"),
        ] {
            memory.apply(.factAccepted(remembered))
        }

        #expect(memory.tree.nodes.map(\.name.rawValue) == ["lives in", "family"])
        #expect(memory.tree.facts.map(\.value) == ["Haar, Germany", "Ann", "Bob"])
        #expect(
            memory.tree.rendered() == """
                You
                ├─ lives in: Haar, Germany
                └─ family
                   ├─ sister: Ann
                   └─ brother: Bob
                """)
        #expect(MemoryRetrieval.recalled(memory.tree).hasSuffix(memory.tree.rendered()))
        #expect(MemoryRetrieval.recalled(memory.tree).contains("may be out of date"))
        #expect(MemoryRetrieval.recalled(Memory().tree) == "Nothing is remembered.")
    }

    /// A path has one to three names, none of them empty.
    @Test
    func aPathHasOneToThreeNames() {
        #expect(MemoryPath([]) == nil)
        #expect(MemoryPath(["family", " "]) == nil)
        #expect(MemoryPath(["a", "b", "c", "d"]) == nil)
        #expect(MemoryPath([" Lives   In "])?.description == "lives in")
        #expect(MemoryPath(["family", "sister"])?.description == "family › sister")
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
            path: MemoryPath(["home"])!,
            value: "Haar",
            evidence: [observationID],
            supportingText: "You live in Haar",
            confidence: 0.95,
            observedAt: observation.observedAt
        )

        #expect(!MemoryEvidence.supports(candidate, in: [observation]))

        let userSupported = FactCandidate(
            path: MemoryPath(["home"])!,
            value: "Haar",
            evidence: [observationID],
            supportingText: "weather in Haar",
            confidence: 0.95,
            observedAt: observation.observedAt
        )
        #expect(MemoryEvidence.supports(userSupported, in: [observation]))
    }

}
