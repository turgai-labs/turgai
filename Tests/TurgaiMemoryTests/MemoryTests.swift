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
        var projection = remembering([fact(["name"], "Ada")])
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
        let proposal = MemoryProposal(facts: [.init(path: ["lives in"], value: "Haar", exchange: 1, confidence: 1)])

        _ = read(proposal, from: [said], into: &memory)

        #expect(memory.currentFacts().map(\.line) == ["lives in: Haar"])
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
            MemoryProposal(facts: [.init(path: ["name"], value: "Ada", exchange: 3, confidence: 1)]),
            from: [first, second], into: &memory)

        #expect(changes.isEmpty)
        #expect(rejected == [.noSuchExchange(3)])
        #expect(memory.unread(in: check).isEmpty)
        #expect(memory.readThrough[check] == second.sourceID)
    }

    /// A new value at a path is kept beside the ones there: liking sushi isn't liking pasta no more.
    @Test
    func aNewValueAtAPathIsKeptBesideTheOthers() {
        var memory = remembering([fact(["likes"], "pasta")])

        _ = read(
            MemoryProposal(facts: [.init(path: ["likes"], value: "sushi", exchange: 1, confidence: 0.9)]),
            from: [message("I also love sushi")], into: &memory)

        #expect(memory.currentFacts().map(\.line) == ["likes: pasta", "likes: sushi"])
        #expect(memory.tree.rendered() == "You\n└─ likes: pasta (1970-01-02) · sushi (1970-01-03)")
    }

    /// Saying what's remembered again, written another way, changes nothing.
    @Test
    func sayingItAgainChangesNothing() {
        var memory = remembering([fact(["lives in"], "Haar")])

        let (changes, rejected) = read(
            MemoryProposal(facts: [.init(path: ["Lives  In"], value: " haar", exchange: 1, confidence: 0.9)]),
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
                facts: [.init(path: ["home"], value: "Berlin", exchange: 1, confidence: 0.9)],
                endings: [.init(line: "Lives in - Haar", exchange: 1), .init(line: "gym: in Haar", exchange: 1)]),
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
            MemoryProposal(endings: [.init(line: "likes: pasta", exchange: 1)]),
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
                facts: [.init(path: ["likes"], value: "tea", exchange: 1, confidence: 0.9)],
                endings: [
                    .init(line: "lives in: Munich", exchange: 1), .init(line: "likes: pasta", exchange: 1),
                    .init(line: "family sister: Kate", exchange: 1),
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

    /// A fact names the new exchange it comes from, read in context: an answer counts by the question
    /// it answers, and a word said before doesn't make it ambiguous. Only new exchanges can be named.
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
                .init(path: ["home"], value: "Haar, Germany", exchange: 4, confidence: 0.95),
                .init(path: ["likes"], value: "snow", exchange: 0, confidence: 0.9),
                .init(path: ["likes"], value: "rain", exchange: 5, confidence: 0.9),
            ]),
            from: [weather, snow, question, answer], into: &memory)

        #expect(rejected == [.noSuchExchange(0), .noSuchExchange(5)])
        #expect(changes.count == 1)
        #expect(memory.currentFacts().map(\.line) == ["home: Haar, Germany"])
        #expect(memory.currentFacts()[0].learned == Said(observation: answer.id, at: answer.observedAt))

        // Read already, the four are context: a new exchange is 1 again.
        let tea = message("I like tea", at: 5)
        let (more, _) = read(
            MemoryProposal(facts: [.init(path: ["likes"], value: "tea", exchange: 1, confidence: 0.9)]),
            from: [tea], into: &memory)
        #expect(more.count == 1)
        #expect(memory.currentFacts()[1].learned.observation == tea.id)
    }

    /// A fact has a path, a value, and is sure enough.
    @Test
    func aFactNeedsAPathAValueAndCertainty() {
        var memory = Memory()
        let (changes, rejected) = read(
            MemoryProposal(facts: [
                .init(path: [], value: "coffee", exchange: 1, confidence: 0.9),
                .init(path: ["a", "b", "c", "d"], value: "coffee", exchange: 1, confidence: 0.9),
                .init(path: ["drinks"], value: " ", exchange: 1, confidence: 0.9),
                .init(path: ["drinks"], value: "coffee", exchange: 1, confidence: 0.5),
            ]),
            from: [message("I drink coffee every morning")], into: &memory)

        #expect(changes.isEmpty)
        #expect(rejected == [.notAPath([]), .notAPath(["a", "b", "c", "d"]), .notAValue(" "), .unsure(0.5)])
    }

    /// An extraction that began before they had their memory forgotten writes nothing.
    @Test
    func aProposalFromBeforeForgettingIsStale() {
        let said = message("I live in Haar")
        var memory = recording([said])
        let input = ExtractionInput(conversation: check, new: [said], generation: memory.generation, existingFacts: [])
        memory.apply(.cleared(at: Date(timeIntervalSince1970: 3 * 86_400)))

        let proposal = MemoryProposal(facts: [.init(path: ["lives in"], value: "Haar", exchange: 1, confidence: 1)])
        #expect(memory.reading(proposal, of: input) == .stale)
    }
}
