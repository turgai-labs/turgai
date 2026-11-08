import TurgaiDomain

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// What the extractor proposed, as it wrote it: nothing in it is checked yet.
public struct MemoryProposal: Codable, Sendable, Equatable {
    /// Something new about the person.
    public struct Fact: Codable, Sendable, Equatable {
        public let relation: MemoryRelation
        public let to: String
        /// The new exchange it comes from, by its number.
        public let exchange: Int

        public init(relation: MemoryRelation, to: String, exchange: Int) {
            self.relation = relation
            self.to = to
            self.exchange = exchange
        }
    }

    /// A fact of their memory that what they said makes untrue.
    public struct Ending: Codable, Sendable, Equatable {
        /// The fact, by its number.
        public let fact: Int
        /// The new exchange that makes it untrue, by its number.
        public let exchange: Int

        public init(fact: Int, exchange: Int) {
            self.fact = fact
            self.exchange = exchange
        }
    }

    public let facts: [Fact]
    public let endings: [Ending]

    public init(facts: [Fact] = [], endings: [Ending] = []) {
        self.facts = facts
        self.endings = endings
    }
}

/// Why part of a proposal changed nothing.
public enum MemoryRejection: Error, Codable, Sendable, Equatable {
    /// No new exchange has the number.
    case noSuchExchange(Int)
    /// No fact remembered has the number, or it's no longer current.
    case noSuchFact(Int)
    case notAName(String)
}

/// What reading a proposal decided.
public enum MemoryReading: Sendable, Equatable {
    /// Their memory was forgotten since the extraction began, or the exchanges came before that.
    case stale
    /// The exchanges were read already.
    case alreadyRead
    /// The exchanges are read: what changed, and what didn't and why.
    case read(MemoryExtractionCommit, rejected: [MemoryRejection])
}

extension Memory {
    /// What `proposal`, made from `input`, does to this memory. Endings come first, each naming a
    /// fact of `input` by its number; then each new fact is learned, unless it's current already,
    /// ending the one it takes the place of when there's one at a time. Each names the new exchange
    /// it comes from: only those, never one read already.
    public func reading(
        _ proposal: MemoryProposal,
        of input: ExtractionInput,
        newID: () -> MemoryFactID = { MemoryFactID() }
    ) -> MemoryReading {
        guard input.generation == generation, input.new.allSatisfy(accepts) else { return .stale }
        guard let last = input.new.last,
            unread(in: input.conversation).contains(where: { $0.sourceID == last.sourceID })
        else { return .alreadyRead }

        var memory = self
        var changes: [MemoryFactEvent] = []
        var rejected: [MemoryRejection] = []
        for part in proposal.endings.map(Part.ending) + proposal.facts.map(Part.fact) {
            let step =
                switch part {
                case .ending(let ending): memory.ending(ending, in: input)
                case .fact(let fact): memory.learning(fact, in: input, id: newID)
                }
            switch step {
            case .changed(let changed):
                for change in changed { memory.applyFactEvent(change) }
                changes += changed
            case .unchanged:
                continue
            case .rejected(let rejection):
                rejected.append(rejection)
            }
        }
        return .read(
            MemoryExtractionCommit(
                generation: input.generation, conversation: input.conversation, readThrough: last.sourceID,
                changes: changes),
            rejected: rejected
        )
    }

    /// One part of a proposal.
    private enum Part {
        case ending(MemoryProposal.Ending)
        case fact(MemoryProposal.Fact)
    }

    /// What one part of a proposal does.
    private enum Step {
        case changed([MemoryFactEvent])
        /// They said what's remembered already.
        case unchanged
        case rejected(MemoryRejection)
    }

    private func ending(_ ending: MemoryProposal.Ending, in input: ExtractionInput) -> Step {
        guard let fact = input.fact(ending.fact), currentFacts().contains(where: { $0.id == fact.id }) else {
            return .rejected(.noSuchFact(ending.fact))
        }
        switch Self.said(in: ending.exchange, of: input) {
        case .success(let said): return .changed([.ended(fact.id, said)])
        case .failure(let rejection): return .rejected(rejection)
        }
    }

    private func learning(
        _ proposed: MemoryProposal.Fact, in input: ExtractionInput, id: () -> MemoryFactID
    ) -> Step {
        guard let name = MemoryName(proposed.to) else { return .rejected(.notAName(proposed.to)) }
        switch Self.said(in: proposed.exchange, of: input) {
        case .failure(let rejection):
            return .rejected(rejection)
        case .success(let said):
            let fact = MemoryFact(id: id(), relation: proposed.relation, to: name, learned: said)
            let current = currentFacts()
            guard !current.contains(where: { $0.isSame(as: fact) }) else { return .unchanged }
            let replaced: [MemoryFact] =
                switch fact.relation.atOnce {
                case .one: current.filter { $0.relation == fact.relation }
                case .many: []
                }
            return .changed(replaced.map { MemoryFactEvent.ended($0.id, said) } + [.learned(fact)])
        }
    }

    /// Where the new exchange numbered `number` was: their message in it, and when.
    private static func said(in number: Int, of input: ExtractionInput) -> Result<Said, MemoryRejection> {
        guard let exchange = input.exchange(number) else { return .failure(.noSuchExchange(number)) }
        return .success(Said(observation: exchange.id, at: exchange.observedAt))
    }
}
