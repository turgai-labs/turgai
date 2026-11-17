import AnyLanguageModel
import DistributedCluster
import Hail
import Logging
import TurgaiDomain
import TurgaiMemory

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// What one extraction pass found the new exchanges show about the person. The User aggregate reads
/// it into their memory: an exchange or a fact it wasn't shown changes nothing.
@Generable(description: "What the new exchanges show about the person.")
public struct MemoryReport: Codable, Sendable {
    @Generable(description: "A fact about the person.")
    public struct Learned: Codable, Sendable {
        public let relation: MemoryRelation
        @Guide(description: "Who or what, by name.")
        public let to: String
        @Guide(description: "The new exchange it comes from.")
        public let exchange: Int
    }

    @Generable(description: "A fact of their memory that's no longer true.")
    public struct Ended: Codable, Sendable {
        @Guide(description: "A fact of their memory, by its number.")
        public let fact: Int
        @Guide(description: "The new exchange that makes it untrue.")
        public let exchange: Int
    }

    public let learned: [Learned]
    public let ended: [Ended]
}

extension MemoryReport {
    /// It as the proposal it is: nothing in it checked.
    var proposal: MemoryProposal {
        MemoryProposal(
            facts: learned.map { MemoryProposal.Fact(relation: $0.relation, to: $0.to, exchange: $0.exchange) },
            endings: ended.map { MemoryProposal.Ending(fact: $0.fact, exchange: $0.exchange) }
        )
    }
}

/// What a pass gives the model: their memory, each fact numbered; the conversation's exchanges read
/// already; and its new ones, numbered.
@Generable
struct MemoryPassInput {
    @Generable
    struct Fact {
        let fact: Int
        let relation: MemoryRelation
        let to: String
    }

    @Generable
    struct Earlier {
        let person: String
        let assistant: String?
    }

    @Generable
    struct New {
        let exchange: Int
        let person: String
        let assistant: String?
    }

    let memory: [Fact]
    let earlier: [Earlier]
    let new: [New]
}

extension MemoryPassInput {
    /// What `input` gives the model: its facts and new exchanges numbered from 1, as it reads them.
    init(_ input: ExtractionInput) {
        self.init(
            memory: input.existingFacts.enumerated().map { index, fact in
                Fact(fact: index + 1, relation: fact.relation, to: fact.to.rawValue)
            },
            earlier: input.earlier.map { Earlier(person: $0.text, assistant: $0.response) },
            new: input.new.enumerated().map { index, exchange in
                New(exchange: index + 1, person: exchange.text, assistant: exchange.response)
            })
    }
}

/// A relation, as a model writes it: one of their names.
extension MemoryRelation: Generable {
    public static var generationSchema: GenerationSchema {
        GenerationSchema(
            type: Self.self, description: "How the person is related to it.", anyOf: allCases.map(\.rawValue))
    }

    public init(_ content: GeneratedContent) throws {
        guard case .string(let written) = content.kind, let relation = Self(rawValue: written) else {
            throw GeneratedContentError.typeMismatch
        }
        self = relation
    }

    public var generatedContent: GeneratedContent {
        GeneratedContent(rawValue)
    }
}

/// Runs one background extraction pass over one conversation: gives the model the person's memory
/// and the conversation's exchanges, those read already as context and the new ones numbered, asks
/// it for the typed report, and returns it.
public enum MemoryExtractionService {
    public static func extract(endpoint: any ModelEndpoint, input: ExtractionInput) async throws -> MemoryReport {
        let shown = MemoryPassInput(input)
        let entries: [Transcript.Entry] = [
            .prompt(
                .init(segments: [
                    .structure(.init(source: String(describing: MemoryPassInput.self), content: shown.generatedContent))
                ]))
        ]

        let stream = endpoint.stream(
            request: ModelRequest(input: entries, entries: entries),
            tools: [],
            authority: FullAuthority(),
            generating: MemoryReport.self,
            purpose: .generation
        )
        for await event in stream {
            switch event {
            case .generated(let value):
                return value
            case .failed(let error):
                throw AgentRuntimeError.modelMisbehavior(String(describing: error))
            default:
                continue
            }
        }
        throw AgentRuntimeError.modelMisbehavior("Memory extraction produced no report")
    }

    /// The pass over `conversation` once its person has gone quiet: it asks for a proposal for
    /// the conversation's new exchanges, and User reads it into their memory, with the write-time
    /// generation and latest-exchange guards. With remembering off, nothing's asked: the new
    /// exchanges are read with nothing kept.
    public static func extractAndCommit(
        endpoint: any ModelEndpoint,
        actorSystem: ClusterSystem,
        user: User,
        conversation: ConversationID,
        expectedLatestSourceID: MemorySourceID
    ) async throws -> ExtractionOutcome {
        let snapshot = try await user.extractionSnapshot(of: conversation)
        guard snapshot.latestObservationSourceID == expectedLatestSourceID else { return .stale }
        guard !snapshot.input.new.isEmpty else { return .alreadyHandled }

        let proposal =
            try await user.currentRemembering() == .on
            ? try await extract(endpoint: endpoint, input: snapshot.input).proposal : MemoryProposal()

        // Keep the input and generation captured before the model call so a
        // concurrent forget cannot associate this report with a new generation.
        let outcome = try await user.commitExtraction(
            snapshot.input,
            proposal: proposal,
            expectedLatestSourceID: expectedLatestSourceID
        )
        if case .committed(let changes, let rejected) = outcome {
            let metadata: Logger.Metadata = [
                "exchanges": "\(snapshot.input.new.count)",
                "changes": "\(changes.count)",
                "rejected": .string(rejected.map { String(describing: $0) }.joined(separator: " | ")),
            ]
            if rejected.isEmpty {
                actorSystem.log.info("Memory extraction pass", metadata: metadata)
            } else {
                actorSystem.log.warning("Memory extraction rejected part of its proposal", metadata: metadata)
            }
        }
        return outcome
    }
}
