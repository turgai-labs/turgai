import AnyLanguageModel
import DistributedCluster
import Hail
import Logging
import TurgaiDomain
import TurgaiMemory
import TurgaiPeople

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// What one extraction pass found a conversation shows about the person. The User aggregate reads
/// it into their memory: an exchange that isn't a new one, or a line that isn't in their memory,
/// changes nothing.
@Generable(description: "What the new exchanges show about the person.")
public struct MemoryExtractionReport: Codable, Sendable {
    @Generable
    public struct MemoryExtractionCandidate: Codable, Sendable {
        @Guide(
            description:
                "Where it goes in their memory: the names from them down, one to three, each a few words."
        )
        public let path: [String]
        @Guide(description: "What it is.")
        public let value: String
        @Guide(description: "The number of the new exchange it comes from.")
        public let exchange: Int
        @Guide(description: "How certain it is that this is true, between 0 and 1.")
        public let confidence: Double
    }

    @Generable
    public struct MemoryExtractionEnding: Codable, Sendable {
        @Guide(description: "A line of their memory, copied exactly.")
        public let line: String
        @Guide(description: "The number of the new exchange that makes it untrue.")
        public let exchange: Int
    }

    public let memories: [MemoryExtractionCandidate]
    @Guide(description: "The lines of their memory that the new exchanges make untrue.")
    public let noLongerTrue: [MemoryExtractionEnding]
}

extension MemoryExtractionReport {
    /// It as the proposal it is: nothing in it checked.
    var proposal: MemoryProposal {
        MemoryProposal(
            facts: memories.map {
                MemoryProposal.Fact(path: $0.path, value: $0.value, exchange: $0.exchange, confidence: $0.confidence)
            },
            endings: noLongerTrue.map { MemoryProposal.Ending(line: $0.line, exchange: $0.exchange) }
        )
    }
}

/// Runs one background extraction pass over one conversation: renders its exchanges as a
/// transcript, those read already as context and the new ones numbered, with the person's memory
/// as it is, asks the model for the typed extraction report, and returns it.
public enum MemoryExtractionService {
    /// Task instructions that are not field requirements belong here; the
    /// generated schema carries the report and field descriptions.
    private static let task = """
        Find what this conversation shows about the person that will matter in later \
        conversations: who they are, where they live, what they like, the people they know, their \
        habits. Read their words together with the replies: what they answer, what they ask about \
        and what they react to can show it as well as what they say outright. Only the new \
        exchanges count; earlier ones are context. Leave out what matters only to this \
        conversation. Put each at a path in their memory, under the names it already has. When the \
        new exchanges make a line of their memory untrue, even without saying so, give that line. \
        Return empty lists when they show nothing about the person.
        """

    public static func extract(endpoint: any ModelEndpoint, input: ExtractionInput) async throws
        -> MemoryExtractionReport
    {
        let lines = MemoryTree(input.existingFacts).facts.map(\.line)
        let memory = lines.isEmpty ? "Their memory is empty." : "Their memory now:\n" + lines.joined(separator: "\n")
        let entries: [Transcript.Entry] = [
            .instructions(
                .init(
                    segments: [.text(.init(content: task))],
                    toolDefinitions: []
                )
            ),
            .prompt(.init(segments: [.text(.init(content: memory + "\n\n" + transcript(input)))])),
        ]

        let stream = endpoint.stream(
            request: ModelRequest(input: entries, entries: entries),
            tools: [],
            authority: FullAuthority(),
            generating: MemoryExtractionReport.self,
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

    /// `input`'s exchanges as the extractor reads them: those read already, unnumbered, then the
    /// new ones, numbered from 1.
    static func transcript(_ input: ExtractionInput) -> String {
        let earlier = input.earlier.flatMap { lines(of: $0, numbered: nil) }
        let new = input.new.enumerated().flatMap { index, exchange in lines(of: exchange, numbered: index + 1) }
        let sections = [
            earlier.isEmpty ? nil : (["Earlier in this conversation, read already:"] + earlier),
            ["New:"] + new,
        ]
        return sections.compactMap { $0?.joined(separator: "\n") }.joined(separator: "\n\n")
    }

    /// One exchange's lines: what the person said, then the reply, under `number` when it's new.
    private static func lines(of exchange: MemoryObservation, numbered number: Int?) -> [String] {
        let label = number.map { " [\($0)]" } ?? ""
        return ["user\(label): \(exchange.text)"] + (exchange.response.map { ["assistant\(label): \($0)"] } ?? [])
    }
}

/// One memory pass: once its author has been quiet for a while, what they said is extracted, tried
/// again after each failure, a while longer each time.
enum MemoryPass {
    /// Whether, after `quiet`, `extract` noted something: tried again after each of `retries` when it
    /// fails, each failure given to `failed`. Cancelled, it notes nothing.
    static func run(
        after quiet: Duration,
        retries: [Duration],
        extract: () async throws -> ExtractionOutcome,
        failed: (any Error) -> Void
    ) async -> Bool {
        do { try await Task.sleep(for: quiet) } catch { return false }
        var waits = retries[...]
        while true {
            do {
                guard case .committed(let changes, _) = try await extract() else { return false }
                return !changes.isEmpty
            } catch is CancellationError {
                return false
            } catch {
                failed(error)
                guard let wait = waits.popFirst() else { return false }
                do { try await Task.sleep(for: wait) } catch { return false }
            }
        }
    }
}
