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

    /// A fact learned on `day`, days since 1970.
    private func fact(_ path: [String], _ value: String, on day: Int = 1, id: MemoryFactID = MemoryFactID())
        -> MemoryFact
    {
        let at = Date(timeIntervalSince1970: TimeInterval(day) * 86_400)
        return MemoryFact(
            id: id, path: MemoryPath(path)!, value: MemoryValue(value)!,
            learned: Said(observation: ObservationID(), at: at), confidence: 0.9)
    }

    /// A memory that's learned `facts`.
    private func remembering(_ facts: [MemoryFact]) -> Memory {
        var memory = Memory()
        memory.apply(
            .extractionCommitted(
                MemoryExtractionCommit(
                    generation: memory.generation, processedSources: [], observations: [],
                    changes: facts.map(MemoryFactEvent.learned))))
        return memory
    }

    /// A message they sent, on day 2.
    private func message(_ text: String, response: String? = nil) -> MemoryObservation {
        MemoryObservation(
            sourceID: MemorySourceID(), text: text, response: response,
            observedAt: Date(timeIntervalSince1970: 2 * 86_400))
    }

    /// What reading `proposal`, made from `messages`, into `memory` changed, and what it rejected.
    private func read(
        _ proposal: MemoryProposal, from messages: [MemoryObservation], into memory: inout Memory,
        newID: MemoryFactID = MemoryFactID()
    ) -> (changes: [MemoryFactEvent], rejected: [MemoryRejection]) {
        let input = ExtractionInput(
            observations: messages, generation: memory.generation, existingFacts: memory.currentFacts())
        guard case .read(let commit, let rejected) = memory.reading(proposal, of: input, newID: { newID }) else {
            Issue.record("Expected the messages to be read")
            return ([], [])
        }
        memory.apply(.extractionCommitted(commit))
        return (commit.changes, rejected)
    }

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
            projection.observations.last?.text
                == "message \(Memory.maximumObservations + 1)"
        )
    }

    @Test
    func clearingMemoryStartsANewGenerationAndRemovesTheProjection() {
        let observation = MemoryObservation(
            id: observationID,
            sourceID: sourceID,
            text: "My name is Ada",
            observedAt: Date(timeIntervalSince1970: 1)
        )
        var projection = remembering([fact(["name"], "Ada")])
        projection.apply(.observationRecorded(observation))
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
        #expect(projection.previousObservations(before: MemorySourceID(), limit: 2).isEmpty)
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

    /// One human's linked persons remember in one tree: the same value at a path once, and
    /// different ones each with the day it was learned, the earliest first.
    @Test
    func linkedPersonsRememberInOneTree() {
        let telegram = [fact(["home"], "Munich", on: 20_390), fact(["sister"], "Ann", on: 20_000)]
        let account = [fact(["home"], "Berlin", on: 20_373), fact(["sister"], "Ann", on: 20_100)]

        #expect(
            MemoryTree(telegram + account).rendered() == """
                You
                ├─ home: Berlin (2025-10-12) · Munich (2025-10-29)
                └─ sister: Ann
                """)
    }

    /// What's remembered is a tree: names a path shares are one node, each fact sits at its path's
    /// last name, and a recall gives it as data that can be out of date.
    @Test
    func whatsRememberedIsATreeOfPaths() {
        let memory = remembering([
            fact(["lives in"], "Haar, Germany"), fact(["family", "sister"], "Ann"), fact(["Family", "brother"], "Bob"),
        ])

        #expect(memory.tree.nodes.map(\.name.rawValue) == ["lives in", "family"])
        #expect(
            memory.tree.facts.map(\.line) == [
                "lives in: Haar, Germany", "family › sister: Ann", "family › brother: Bob",
            ])
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

    /// A path has one to three names, none of them empty or too long.
    @Test
    func aPathHasOneToThreeNames() {
        #expect(MemoryPath([]) == nil)
        #expect(MemoryPath(["family", " "]) == nil)
        #expect(MemoryPath([String(repeating: "a", count: MemoryName.maximumLength + 1)]) == nil)
        #expect(MemoryPath(["a", "b", "c", "d"]) == nil)
        #expect(MemoryPath([" Lives   In "])?.description == "lives in")
        #expect(MemoryPath(["family", "sister"])?.description == "family › sister")
    }

    // MARK: Reading what they said

    /// Their messages are read once: reading them again changes nothing.
    @Test
    func messagesAreReadOnce() {
        let said = message("I live in Haar")
        var memory = Memory()
        let proposal = MemoryProposal(facts: [
            .init(path: ["lives in"], value: "Haar", quote: "I live in Haar", confidence: 1)
        ])

        _ = read(proposal, from: [said], into: &memory)

        #expect(memory.currentFacts().map(\.line) == ["lives in: Haar"])
        #expect(memory.isProcessed(said))
        let again = ExtractionInput(
            observations: [said], generation: memory.generation, existingFacts: memory.currentFacts())
        #expect(memory.reading(proposal, of: again) == .alreadyRead)
    }

    /// Every message in the batch is read, even when nothing in the proposal is kept.
    @Test
    func theBatchIsReadEvenWhenNothingIsKept() {
        let first = message("My name is Ada")
        let second = message("thanks")
        var memory = Memory()

        let (changes, rejected) = read(
            MemoryProposal(facts: [.init(path: ["name"], value: "Ada", quote: "nowhere", confidence: 1)]),
            from: [first, second], into: &memory)

        #expect(changes.isEmpty)
        #expect(rejected == [.notSaid(quote: "nowhere")])
        #expect(memory.isProcessed(first))
        #expect(memory.isProcessed(second))
    }

    /// A new value at a path is kept beside the ones there: liking sushi isn't liking pasta no more.
    @Test
    func aNewValueAtAPathIsKeptBesideTheOthers() {
        var memory = remembering([fact(["likes"], "pasta")])

        _ = read(
            MemoryProposal(facts: [.init(path: ["likes"], value: "sushi", quote: "I also love sushi", confidence: 0.9)]
            ),
            from: [message("I also love sushi")], into: &memory)

        #expect(memory.currentFacts().map(\.line) == ["likes: pasta", "likes: sushi"])
        #expect(memory.tree.rendered() == "You\n└─ likes: pasta (1970-01-02) · sushi (1970-01-03)")
    }

    /// Saying what's remembered again, written another way, changes nothing.
    @Test
    func sayingItAgainChangesNothing() {
        var memory = remembering([fact(["lives in"], "Haar")])

        let (changes, rejected) = read(
            MemoryProposal(facts: [.init(path: ["Lives  In"], value: " haar", quote: "I live in haar", confidence: 0.9)]
            ),
            from: [message("I live in Haar")], into: &memory)

        #expect(changes.isEmpty)
        #expect(rejected.isEmpty)
        #expect(memory.currentFacts().map(\.line) == ["lives in: Haar"])
    }

    /// Moving ends every line it makes untrue, at any path, and what ended is kept, ended, with
    /// where they said it.
    @Test
    func aMoveEndsWhatItMakesUntrue() {
        let haar = fact(["lives in"], "Haar")
        let gym = fact(["gym"], "in Haar")
        var memory = remembering([haar, gym, fact(["likes"], "pasta")])
        let keys = message("We just got the keys to our flat in Berlin!")
        let berlin = MemoryFactID()

        let (changes, rejected) = read(
            MemoryProposal(
                facts: [.init(path: ["home"], value: "Berlin", quote: "our flat in Berlin", confidence: 0.9)],
                endings: [
                    .init(line: "Lives in - Haar", quote: "got the keys to our flat in Berlin"),
                    .init(line: "gym: in Haar", quote: "got the keys to our flat in Berlin"),
                ]),
            from: [keys], into: &memory, newID: berlin)

        let said = Said(observation: keys.id, at: keys.observedAt)
        #expect(rejected.isEmpty)
        #expect(changes.count == 3)
        #expect(changes.prefix(2) == [.ended(haar.id, said), .ended(gym.id, said)])
        #expect(memory.currentFacts().map(\.line) == ["likes: pasta", "home: Berlin"])
        #expect(memory.currentFacts().last?.id == berlin)
        #expect(memory.facts.first { $0.id == haar.id }?.status == .ended(said))
        #expect(!memory.tree.rendered().contains("Haar"))
    }

    /// What they say can end a fact without telling anything new.
    @Test
    func anEndingNeedsNoNewFact() {
        let pasta = fact(["likes"], "pasta")
        var memory = remembering([pasta, fact(["likes"], "sushi")])
        let stopped = message("I don't eat pasta anymore")

        let (changes, _) = read(
            MemoryProposal(endings: [.init(line: "likes: pasta", quote: "I don't eat pasta anymore")]),
            from: [stopped], into: &memory)

        #expect(changes == [.ended(pasta.id, Said(observation: stopped.id, at: stopped.observedAt))])
        #expect(memory.currentFacts().map(\.line) == ["likes: sushi"])
    }

    /// An ending names exactly one current fact by its line; one that doesn't changes nothing, and
    /// the rest of the proposal stands.
    @Test
    func anEndingMustNameOneCurrentFact() {
        let pasta = fact(["likes"], "pasta")
        var memory = remembering([
            fact(["lives in"], "Haar"), pasta, fact(["family", "sister"], "Kate"), fact(["family sister"], "Kate"),
        ])
        memory.apply(.factForgotten(pasta.id))
        let said = message("I moved to Munich, I like tea, and Kate is my sister")

        let (changes, rejected) = read(
            MemoryProposal(
                facts: [.init(path: ["likes"], value: "tea", quote: "I like tea", confidence: 0.9)],
                endings: [
                    .init(line: "lives in: Munich", quote: "I moved to Munich"),
                    .init(line: "likes: pasta", quote: "I like tea"),
                    .init(line: "family sister: Kate", quote: "Kate is my sister"),
                ]),
            from: [said], into: &memory)

        #expect(
            rejected == [
                .notRemembered(line: "lives in: Munich"), .notRemembered(line: "likes: pasta"),
                .notRemembered(line: "family sister: Kate"),
            ])
        #expect(changes.count == 1)
        #expect(memory.currentFacts().map(\.line).contains("likes: tea"))
        #expect(memory.currentFacts().map(\.line).contains("lives in: Haar"))
    }

    /// A quote must be the person's own words, in exactly one message the extractor saw: never a
    /// reply, and a short answer counts by its own words.
    @Test
    func aQuoteIsTheirWordsInOneMessage() {
        let question = message("Weather please", response: "Which location? You live in Haar, right?")
        let answer = message("Haar, Germany")
        let again = message("Haar, Germany is lovely")
        var memory = Memory()
        func learning(_ quote: String) -> MemoryProposal {
            MemoryProposal(facts: [.init(path: ["lives in"], value: "Haar", quote: quote, confidence: 0.9)])
        }
        let input = ExtractionInput(
            observations: [answer], generation: memory.generation, existingFacts: [],
            previousObservations: [question, answer, again])

        for (quote, rejection) in [
            ("You live in Haar", MemoryRejection.notSaid(quote: "You live in Haar")),
            ("Haar, Germany", .saidInSeveral(quote: "Haar, Germany")),
        ] {
            guard case .read(_, let rejected) = memory.reading(learning(quote), of: input) else {
                Issue.record("Expected the messages to be read")
                continue
            }
            #expect(rejected == [rejection])
        }

        // The same message twice, as current and as context, is one message.
        let (changes, rejected) = read(learning("Haar, Germany is lovely"), from: [again, again], into: &memory)
        #expect(rejected.isEmpty)
        #expect(changes == [.learned(memory.currentFacts()[0])])
        #expect(memory.currentFacts()[0].learned == Said(observation: again.id, at: again.observedAt))
    }

    /// A fact has a path, a value, and is sure enough.
    @Test
    func aFactNeedsAPathAValueAndCertainty() {
        var memory = Memory()
        let quote = "I drink coffee every morning"

        let (changes, rejected) = read(
            MemoryProposal(facts: [
                .init(path: [], value: "coffee", quote: quote, confidence: 0.9),
                .init(path: ["a", "b", "c", "d"], value: "coffee", quote: quote, confidence: 0.9),
                .init(path: ["drinks"], value: " ", quote: quote, confidence: 0.9),
                .init(path: ["drinks"], value: "coffee", quote: quote, confidence: 0.5),
            ]),
            from: [message(quote)], into: &memory)

        #expect(changes.isEmpty)
        #expect(rejected == [.notAPath([]), .notAPath(["a", "b", "c", "d"]), .notAValue(" "), .unsure(0.5)])
    }

    /// An extraction that began before they had their memory forgotten writes nothing.
    @Test
    func aProposalFromBeforeForgettingIsStale() {
        let said = message("I live in Haar")
        var memory = Memory()
        let input = ExtractionInput(observations: [said], generation: memory.generation, existingFacts: [])
        memory.apply(.cleared(at: Date(timeIntervalSince1970: 3 * 86_400)))

        #expect(
            memory.reading(
                MemoryProposal(facts: [.init(path: ["lives in"], value: "Haar", quote: "I live in Haar", confidence: 1)]
                ),
                of: input) == .stale)
    }
}
