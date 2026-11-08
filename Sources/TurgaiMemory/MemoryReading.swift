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
        public let path: [String]
        public let value: String
        /// The new exchange it comes from, by its number.
        public let exchange: Int
        public let confidence: Double

        public init(path: [String], value: String, exchange: Int, confidence: Double) {
            self.path = path
            self.value = value
            self.exchange = exchange
            self.confidence = confidence
        }
    }

    /// A line of their memory that what they said makes untrue.
    public struct Ending: Codable, Sendable, Equatable {
        public let line: String
        /// The new exchange that makes it untrue, by its number.
        public let exchange: Int

        public init(line: String, exchange: Int) {
            self.line = line
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
    case notAPath([String])
    case notAValue(String)
    /// Less sure than a fact needs.
    case unsure(Double)
    /// The line is no current fact's, or several's.
    case notRemembered(line: String)
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
    /// How sure a fact must be, at least.
    public static let minimumConfidence = 0.7

    /// What `proposal`, made from `input`, does to this memory. Endings come first, each naming a
    /// current fact by its line; then each new fact is learned, unless it's current already. Each
    /// names the new exchange it comes from: only those, never one read already.
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
            case .changed(let change):
                memory.applyFactEvent(change)
                changes.append(change)
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
        case changed(MemoryFactEvent)
        /// They said what's remembered already.
        case unchanged
        case rejected(MemoryRejection)
    }

    private func ending(_ ending: MemoryProposal.Ending, in input: ExtractionInput) -> Step {
        let line = Self.comparable(ending.line)
        let named = currentFacts().filter { Self.comparable($0.line) == line }
        guard named.count == 1, let fact = named.first else { return .rejected(.notRemembered(line: ending.line)) }
        switch Self.said(in: ending.exchange, of: input) {
        case .success(let said): return .changed(.ended(fact.id, said))
        case .failure(let rejection): return .rejected(rejection)
        }
    }

    private func learning(
        _ fact: MemoryProposal.Fact, in input: ExtractionInput, id: () -> MemoryFactID
    ) -> Step {
        guard let path = MemoryPath(fact.path) else { return .rejected(.notAPath(fact.path)) }
        guard let value = MemoryValue(fact.value) else { return .rejected(.notAValue(fact.value)) }
        guard fact.confidence >= Self.minimumConfidence else { return .rejected(.unsure(fact.confidence)) }
        switch Self.said(in: fact.exchange, of: input) {
        case .failure(let rejection):
            return .rejected(rejection)
        case .success(let said):
            guard !currentFacts().contains(where: { $0.path == path && $0.value.isSame(as: value) }) else {
                return .unchanged
            }
            return .changed(
                .learned(MemoryFact(id: id(), path: path, value: value, learned: said, confidence: fact.confidence)))
        }
    }

    /// Where the new exchange numbered `number` was: their message in it, and when.
    private static func said(in number: Int, of input: ExtractionInput) -> Result<Said, MemoryRejection> {
        guard let exchange = input.exchange(number) else { return .failure(.noSuchExchange(number)) }
        return .success(Said(observation: exchange.id, at: exchange.observedAt))
    }

    /// `text` as lines are compared: models copy loosely, so case, punctuation, and spacing aside.
    private static func comparable(_ text: String) -> String {
        text
            .lowercased()
            .filter { $0.isLetter || $0.isNumber || $0.isWhitespace }
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}
