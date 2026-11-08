import Testing
import TurgaiDomain
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
    private let check = ConversationID(stableKey: "turgai:check")!
    private let skylark = ConversationID(stableKey: "turgai:skylark")!
    private let turgai = AgentProfileID("turgai")

    /// A fact learned on `day`, days since 1970.
    private func fact(
        _ relation: MemoryRelation, _ to: String, on day: Int = 1, id: MemoryFactID = MemoryFactID()
    ) -> MemoryFact {
        let at = Date(timeIntervalSince1970: TimeInterval(day) * 86_400)
        return MemoryFact(
            id: id, relation: relation, to: MemoryName(to)!, learned: Said(observation: ObservationID(), at: at))
    }

    /// A memory that's learned `facts`.
    private func remembering(_ facts: [MemoryFact]) -> Memory {
        var memory = Memory()
        memory.apply(
            .extractionCommitted(
                MemoryExtractionCommit(
                    generation: memory.generation, conversation: skylark, readThrough: MemorySourceID(),
                    changes: facts.map(MemoryFactEvent.learned))))
        return memory
    }

    /// An exchange they had in `conversation`, on day 2, or at `seconds` since 1970.
    private func message(
        _ text: String, response: String? = nil, in conversation: ConversationID? = nil, at seconds: Int = 2 * 86_400,
        id: ObservationID = ObservationID(), sourceID: MemorySourceID = MemorySourceID()
    ) -> MemoryObservation {
        MemoryObservation(
            id: id, sourceID: sourceID, conversation: conversation ?? check, heardBy: turgai, text: text,
            response: response, observedAt: Date(timeIntervalSince1970: TimeInterval(seconds)))
    }

    /// A memory that's recorded `messages`.
    private func recording(_ messages: [MemoryObservation], into memory: Memory = Memory()) -> Memory {
        var memory = memory
        for message in messages { memory.apply(.observationRecorded(message)) }
        return memory
    }

    /// What reading `proposal`, made from `messages` as Check's new exchanges, into `memory` changed,
    /// and what it rejected.
    private func read(
        _ proposal: MemoryProposal, from messages: [MemoryObservation], into memory: inout Memory,
        newID: MemoryFactID = MemoryFactID()
    ) -> (changes: [MemoryFactEvent], rejected: [MemoryRejection]) {
        memory = recording(messages, into: memory)
        let input = ExtractionInput(
            conversation: check, new: memory.unread(in: check), generation: memory.generation,
            existingFacts: memory.currentFacts())
        guard case .read(let commit, let rejected) = memory.reading(proposal, of: input, newID: { newID }) else {
            Issue.record("Expected the messages to be read")
            return ([], [])
        }
        memory.apply(.extractionCommitted(commit))
        return (commit.changes, rejected)
    }

    @Test
    func observationProjectionIsIdempotentAndBoundedBySourceMessage() {
        let observation = message("Berlin", at: 1, id: observationID, sourceID: sourceID)
        var projection = Memory()

        projection.apply(.observationRecorded(observation))
        projection.apply(.observationRecorded(observation))

        #expect(projection.observations == [observation])
        #expect(projection.containsObservation(for: sourceID))
    }

    /// A conversation's latest exchange is the last kept, even when turns finish out of order, and
    /// another conversation's doesn't count.
    @Test
    func latestExchangeUsesJournalOrderWhenTurnsFinishOutOfOrder() {
        let laterMessage = message("sent later, completed first", at: 2)
        let earlierMessage = message("sent earlier, completed later", at: 1)
        let elsewhere = message("elsewhere", in: skylark, at: 3)
        let projection = recording([laterMessage, earlierMessage, elsewhere])

        #expect(projection.latestObservation(in: check) == earlierMessage)
        #expect(projection.latestObservation(in: skylark) == elsewhere)
    }

    @Test
    func observationTailDropsOldestObservationsBeyondTheCap() {
        var projection = Memory()
        projection.apply(.observationRecorded(message("first", at: 1, sourceID: sourceID)))

        for index in 2...(Memory.maximumObservations + 1) {
            projection.apply(.observationRecorded(message("message \(index)", at: index)))
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
        let observation = message("My name is Ada", at: 1, id: observationID, sourceID: sourceID)
        var projection = remembering([fact(.name, "Ada")])
        projection.apply(.observationRecorded(observation))
        let generation = projection.generation

        projection.apply(.cleared(at: Date(timeIntervalSince1970: 2)))

        #expect(projection.observations.isEmpty)
        #expect(projection.facts.isEmpty)
        #expect(projection.readThrough.isEmpty)
        #expect(projection.generation == generation.advancing())
    }

    @Test
    func observationsFromBeforeForgetCannotEnterTheNewGeneration() {
        var projection = Memory()
        projection.apply(.cleared(at: Date(timeIntervalSince1970: 10)))

        #expect(!projection.accepts(message("old", at: 9)))
        #expect(projection.accepts(message("new", at: 11)))
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

    /// Each conversation has its own cursor: what's past it is new, the last few up to it are what
    /// was read, and one conversation's exchanges never count in another's.
    @Test
    func eachConversationIsReadFromItsOwnCursor() {
        let question = message("Where do I live?", at: 1)
        let tatar = message("How is a skylark called in Tatar?", in: skylark, at: 2)
        let answer = message("Haar", at: 3)
        var memory = recording([question, tatar, answer])

        #expect(memory.unread(in: check) == [question, answer])
        #expect(memory.read(in: check, last: 5).isEmpty)
        memory.apply(
            .extractionCommitted(
                MemoryExtractionCommit(
                    generation: memory.generation, conversation: check, readThrough: question.sourceID,
                    changes: [])))
        #expect(memory.unread(in: check) == [answer])
        #expect(memory.read(in: check, last: 5) == [question])
        #expect(memory.unread(in: skylark) == [tatar])

        let later = message("I like tea", at: 4)
        memory = recording([later], into: memory)
        memory.apply(
            .extractionCommitted(
                MemoryExtractionCommit(
                    generation: memory.generation, conversation: check, readThrough: answer.sourceID,
                    changes: [])))
        #expect(memory.unread(in: check) == [later])
        #expect(memory.read(in: check, last: 1) == [answer])
    }

    /// One human's linked persons are remembered in one: a line for each relation, each name once,
    /// the earliest learned first.
    @Test
    func linkedPersonsAreRememberedInOne() {
        let telegram = [fact(.livesIn, "Munich", on: 20_390), fact(.sibling, "Ann", on: 20_000)]
        let account = [fact(.livesIn, "Berlin", on: 20_373), fact(.sibling, "ann", on: 20_100)]

        let remembered = Remembered(telegram + account)
        #expect(remembered.lines.map(\.relation) == [.livesIn, .sibling])
        #expect(remembered.lines.map(\.said) == ["Berlin · Munich", "Ann"])
    }

    /// What's remembered is a line for each relation, in the order relations are listed, with whom
    /// or what in the order learned.
    @Test
    func whatsRememberedIsALineForEachRelation() {
        let memory = remembering([
            fact(.likes, "pasta"), fact(.sibling, "Ann"), fact(.livesIn, "Haar, Germany"), fact(.likes, "sushi"),
        ])

        #expect(memory.remembered.lines.map(\.relation) == [.livesIn, .likes, .sibling])
        #expect(memory.remembered.lines.map(\.said) == ["Haar, Germany", "pasta · sushi", "Ann"])
        #expect(
            memory.remembered.facts.map(\.line) == [
                "Lives in: Haar, Germany", "Likes: pasta", "Likes: sushi", "Sibling: Ann",
            ])
        #expect(Memory().remembered.isEmpty)
    }

    /// What they see of their memory changes with what's learned, ended, forgotten, or remembering
    /// turned on or off; not with a message kept for reading, or a read that kept nothing.
    @Test
    func someEventsChangeWhatsRemembered() {
        let read = MemoryExtractionCommit(
            generation: .initial, conversation: check, readThrough: MemorySourceID(), changes: [])
        let learned = MemoryExtractionCommit(
            generation: .initial, conversation: check, readThrough: MemorySourceID(),
            changes: [.learned(fact(.livesIn, "Haar"))])

        #expect(!MemoryEvent.observationRecorded(message("Haar")).changesWhatsRemembered)
        #expect(!MemoryEvent.extractionCommitted(read).changesWhatsRemembered)
        #expect(MemoryEvent.extractionCommitted(learned).changesWhatsRemembered)
        #expect(MemoryEvent.factForgotten(factID).changesWhatsRemembered)
        #expect(MemoryEvent.rememberingChanged(.off).changesWhatsRemembered)
        #expect(MemoryEvent.cleared(at: Date()).changesWhatsRemembered)
    }

    /// A name is what was written, its spaces collapsed, never empty or too long, and the same as
    /// another whatever their case.
    @Test
    func aNameIsWhatWasWritten() {
        #expect(MemoryName("") == nil)
        #expect(MemoryName("  ") == nil)
        #expect(MemoryName(String(repeating: "a", count: MemoryName.maximumLength + 1)) == nil)
        #expect(MemoryName(" Haar,   Germany ")?.rawValue == "Haar, Germany")
        #expect(MemoryName("haar")!.isSame(as: MemoryName("Haar")!))
    }

    // MARK: Reading what they said

    /// Their messages are read once: reading them again changes nothing.
    @Test
    func messagesAreReadOnce() {
        let said = message("I live in Haar")
        var memory = Memory()
        let proposal = MemoryProposal(facts: [.init(relation: .livesIn, to: "Haar", exchange: 1)])

        _ = read(proposal, from: [said], into: &memory)

        #expect(memory.currentFacts().map(\.line) == ["Lives in: Haar"])
        #expect(memory.unread(in: check).isEmpty)
        let again = ExtractionInput(
            conversation: check, new: [said], generation: memory.generation, existingFacts: memory.currentFacts())
        #expect(memory.reading(proposal, of: again) == .alreadyRead)
    }

    /// Every new exchange is read, even when nothing in the proposal is kept.
    @Test
    func theNewExchangesAreReadEvenWhenNothingIsKept() {
        let first = message("My name is Ada")
        let second = message("thanks")
        var memory = Memory()

        let (changes, rejected) = read(
            MemoryProposal(facts: [.init(relation: .name, to: "Ada", exchange: 3)]),
            from: [first, second], into: &memory)

        #expect(changes.isEmpty)
        #expect(rejected == [.noSuchExchange(3)])
        #expect(memory.unread(in: check).isEmpty)
        #expect(memory.readThrough[check] == second.sourceID)
    }

    /// A relation they have many of keeps each: liking sushi isn't liking pasta no more.
    @Test
    func aRelationTheyHaveManyOfKeepsEach() {
        var memory = remembering([fact(.likes, "pasta")])

        _ = read(
            MemoryProposal(facts: [.init(relation: .likes, to: "sushi", exchange: 1)]),
            from: [message("I also love sushi")], into: &memory)

        #expect(memory.currentFacts().map(\.line) == ["Likes: pasta", "Likes: sushi"])
    }

    /// Saying what's remembered again, written another way, changes nothing.
    @Test
    func sayingItAgainChangesNothing() {
        var memory = remembering([fact(.livesIn, "Haar")])

        let (changes, rejected) = read(
            MemoryProposal(facts: [.init(relation: .livesIn, to: " haar", exchange: 1)]),
            from: [message("I live in Haar")], into: &memory)

        #expect(changes.isEmpty)
        #expect(rejected.isEmpty)
        #expect(memory.currentFacts().map(\.line) == ["Lives in: Haar"])
    }

    /// A relation they have one of at a time ends the one before, once, whether or not the proposal
    /// ends it too; and what ended is kept, ended, with where they said it.
    @Test
    func aNewHomeEndsTheOldOne() {
        let haar = fact(.livesIn, "Haar")
        var memory = remembering([haar, fact(.likes, "pasta")])
        let keys = message("We just got the keys to our flat in Berlin!", at: 2 * 86_400)
        let berlin = MemoryFactID()

        let (changes, rejected) = read(
            MemoryProposal(
                facts: [.init(relation: .livesIn, to: "Berlin", exchange: 1)],
                endings: [.init(fact: 1, exchange: 1)]),
            from: [keys], into: &memory, newID: berlin)

        let said = Said(observation: keys.id, at: keys.observedAt)
        #expect(rejected.isEmpty)
        #expect(changes.count == 2)
        #expect(changes.first == .ended(haar.id, said))
        #expect(memory.currentFacts().map(\.line) == ["Likes: pasta", "Lives in: Berlin"])
        #expect(memory.facts.first { $0.id == haar.id }?.status == .ended(said))

        let moved = message("Moved to Munich last week", at: 3 * 86_400)
        let (later, _) = read(
            MemoryProposal(facts: [.init(relation: .livesIn, to: "Munich", exchange: 1)]),
            from: [moved], into: &memory)
        #expect(later.first == .ended(berlin, Said(observation: moved.id, at: moved.observedAt)))
        #expect(memory.currentFacts().map(\.line) == ["Likes: pasta", "Lives in: Munich"])
    }

    /// What they say can end a fact without telling anything new.
    @Test
    func anEndingNeedsNoNewFact() {
        let pasta = fact(.likes, "pasta")
        var memory = remembering([pasta, fact(.likes, "sushi")])
        let stopped = message("I don't eat pasta anymore")

        let (changes, _) = read(
            MemoryProposal(endings: [.init(fact: 1, exchange: 1)]),
            from: [stopped], into: &memory)

        #expect(changes == [.ended(pasta.id, Said(observation: stopped.id, at: stopped.observedAt))])
        #expect(memory.currentFacts().map(\.line) == ["Likes: sushi"])
    }

    /// An ending names a fact the extractor was shown, by its number, that's still current; one
    /// that doesn't changes nothing, and the rest of the proposal stands.
    @Test
    func anEndingNamesACurrentFactItWasShown() {
        let haar = fact(.livesIn, "Haar")
        let pasta = fact(.likes, "pasta")
        var memory = recording([message("I like tea, and pasta isn't for me")], into: remembering([haar, pasta]))
        let input = ExtractionInput(
            conversation: check, new: memory.unread(in: check), generation: memory.generation,
            existingFacts: memory.currentFacts())
        memory.apply(.factForgotten(pasta.id))

        guard
            case .read(let commit, let rejected) = memory.reading(
                MemoryProposal(
                    facts: [.init(relation: .likes, to: "tea", exchange: 1)],
                    endings: [.init(fact: 0, exchange: 1), .init(fact: 3, exchange: 1), .init(fact: 2, exchange: 1)]),
                of: input)
        else {
            Issue.record("Expected the messages to be read")
            return
        }
        memory.apply(.extractionCommitted(commit))

        #expect(rejected == [.noSuchFact(0), .noSuchFact(3), .noSuchFact(2)])
        #expect(memory.currentFacts().map(\.line) == ["Lives in: Haar", "Likes: tea"])
    }

    /// A fact names the new exchange it comes from, read in context: an answer counts by the question
    /// it answers. Only new exchanges can be named.
    @Test
    func aFactComesFromANewExchangeReadInContext() {
        let weather = message(
            "What's the weather forecast in Haar Germany for upcoming week?",
            response: "Here's the week ahead in Haar, Germany (near Munich).", at: 1)
        let snow = message("oof, really snow?", response: "Yep, afraid so.", at: 2)
        let question = message(
            "Where I'm living?", response: "Honestly, I don't know. Want to tell me?", at: 3)
        let answer = message("Haar", response: "Got it — Haar, Germany it is.", at: 4)
        var memory = Memory()

        let (changes, rejected) = read(
            MemoryProposal(facts: [
                .init(relation: .livesIn, to: "Haar, Germany", exchange: 4),
                .init(relation: .likes, to: "snow", exchange: 0),
                .init(relation: .likes, to: "rain", exchange: 5),
            ]),
            from: [weather, snow, question, answer], into: &memory)

        #expect(rejected == [.noSuchExchange(0), .noSuchExchange(5)])
        #expect(changes.count == 1)
        #expect(memory.currentFacts().map(\.line) == ["Lives in: Haar, Germany"])
        #expect(memory.currentFacts()[0].learned == Said(observation: answer.id, at: answer.observedAt))

        // Read already, the four are context: a new exchange is 1 again.
        let tea = message("I like tea", at: 5)
        let (more, _) = read(
            MemoryProposal(facts: [.init(relation: .likes, to: "tea", exchange: 1)]),
            from: [tea], into: &memory)
        #expect(more.count == 1)
        #expect(memory.currentFacts()[1].learned.observation == tea.id)
    }

    /// A fact names someone or something.
    @Test
    func aFactNamesSomething() {
        var memory = Memory()
        let long = String(repeating: "a", count: MemoryName.maximumLength + 1)
        let (changes, rejected) = read(
            MemoryProposal(facts: [
                .init(relation: .likes, to: " ", exchange: 1), .init(relation: .likes, to: long, exchange: 1),
            ]),
            from: [message("I drink coffee every morning")], into: &memory)

        #expect(changes.isEmpty)
        #expect(rejected == [.notAName(" "), .notAName(long)])
    }

    /// An extraction that began before they had their memory forgotten writes nothing.
    @Test
    func aProposalFromBeforeForgettingIsStale() {
        let said = message("I live in Haar")
        var memory = recording([said])
        let input = ExtractionInput(conversation: check, new: [said], generation: memory.generation, existingFacts: [])
        memory.apply(.cleared(at: Date(timeIntervalSince1970: 3 * 86_400)))

        let proposal = MemoryProposal(facts: [.init(relation: .livesIn, to: "Haar", exchange: 1)])
        #expect(memory.reading(proposal, of: input) == .stale)
    }
}
