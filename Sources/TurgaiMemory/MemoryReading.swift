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
        /// Their words it comes from.
        public let quote: String
        public let confidence: Double

        public init(path: [String], value: String, quote: String, confidence: Double) {
            self.path = path
            self.value = value
            self.quote = quote
            self.confidence = confidence
        }
    }

    /// A line of their memory that what they said makes untrue.
    public struct Ending: Codable, Sendable, Equatable {
        public let line: String
        /// Their words that make it untrue.
        public let quote: String

        public init(line: String, quote: String) {
            self.line = line
            self.quote = quote
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
    /// The quote is in none of the messages the extractor saw.
    case notSaid(quote: String)
    /// The quote is in more than one of them.
    case saidInSeveral(quote: String)
    case notAPath([String])
    case notAValue(String)
    /// Less sure than a fact needs.
    case unsure(Double)
    /// The line is no current fact's, or several's.
    case notRemembered(line: String)
}

/// What reading a proposal decided.
public enum MemoryReading: Sendable, Equatable {
    /// Their memory was forgotten since the extraction began, or the messages came before that.
    case stale
    /// The messages were read already.
    case alreadyRead
    /// The messages are read: what changed, and what didn't and why.
    case read(MemoryExtractionCommit, rejected: [MemoryRejection])
}

extension Memory {
    /// How sure a fact must be, at least.
    public static let minimumConfidence = 0.7

    /// What `proposal`, made from `input`, does to this memory. Endings come first, each naming a
    /// current fact by its line; then each new fact is learned, unless it's current already. Every
    /// quote must be the person's own words in exactly one message the extractor saw.
    public func reading(
        _ proposal: MemoryProposal,
        of input: ExtractionInput,
        newID: () -> MemoryFactID = { MemoryFactID() }
    ) -> MemoryReading {
        guard input.generation == generation, input.observations.allSatisfy(accepts) else { return .stale }
        guard !input.observations.isEmpty, !input.observations.allSatisfy(isProcessed) else { return .alreadyRead }

        let seen = input.chronologicalObservations
        var memory = self
        var changes: [MemoryFactEvent] = []
        var rejected: [MemoryRejection] = []
        for part in proposal.endings.map(Part.ending) + proposal.facts.map(Part.fact) {
            let step =
                switch part {
                case .ending(let ending): memory.ending(ending, in: seen)
                case .fact(let fact): memory.learning(fact, in: seen, id: newID)
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
                generation: input.generation,
                processedSources: input.observations.map(\.sourceID),
                observations: input.observations,
                changes: changes
            ),
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

    private func ending(_ ending: MemoryProposal.Ending, in seen: [MemoryObservation]) -> Step {
        let line = Self.comparable(ending.line)
        let named = currentFacts().filter { Self.comparable($0.line) == line }
        guard named.count == 1, let fact = named.first else { return .rejected(.notRemembered(line: ending.line)) }
        switch Self.said(ending.quote, in: seen) {
        case .success(let said): return .changed(.ended(fact.id, said))
        case .failure(let rejection): return .rejected(rejection)
        }
    }

    private func learning(
        _ fact: MemoryProposal.Fact, in seen: [MemoryObservation], id: () -> MemoryFactID
    ) -> Step {
        guard let path = MemoryPath(fact.path) else { return .rejected(.notAPath(fact.path)) }
        guard let value = MemoryValue(fact.value) else { return .rejected(.notAValue(fact.value)) }
        guard fact.confidence >= Self.minimumConfidence else { return .rejected(.unsure(fact.confidence)) }
        switch Self.said(fact.quote, in: seen) {
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

    /// Where `quote` was said: the one message in `seen` whose text has it. Only what the person
    /// wrote counts, never a reply.
    private static func said(_ quote: String, in seen: [MemoryObservation]) -> Result<Said, MemoryRejection> {
        let quoted = comparable(quote)
        var saidIn: [ObservationID: MemoryObservation] = [:]
        for message in seen where !quoted.isEmpty && comparable(message.text).contains(quoted) {
            saidIn[message.id] = message
        }
        guard let message = saidIn.values.first else { return .failure(.notSaid(quote: quote)) }
        guard saidIn.count == 1 else { return .failure(.saidInSeveral(quote: quote)) }
        return .success(Said(observation: message.id, at: message.observedAt))
    }

    /// `text` as quotes and lines are compared: models copy loosely, so case, punctuation, and
    /// spacing aside.
    private static func comparable(_ text: String) -> String {
        text
            .lowercased()
            .filter { $0.isLetter || $0.isNumber || $0.isWhitespace }
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}
