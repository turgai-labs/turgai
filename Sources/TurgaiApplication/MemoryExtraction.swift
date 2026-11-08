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

/// What one extraction pass found the person said about themselves. The User
/// aggregate reads it into their memory: a quote that isn't their own words, or
/// a line that isn't in their memory, changes nothing.
@Generable(description: "What the person said about themselves.")
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
        @Guide(description: "The words it comes from, copied exactly from the person's own message.")
        public let quote: String
        @Guide(description: "How certain it is that this is true, between 0 and 1.")
        public let confidence: Double
    }

    @Generable
    public struct MemoryExtractionEnding: Codable, Sendable {
        @Guide(description: "A line of their memory, copied exactly.")
        public let line: String
        @Guide(description: "The words that make it untrue, copied exactly from the person's own message.")
        public let quote: String
    }

    public let memories: [MemoryExtractionCandidate]
    @Guide(description: "The lines of their memory that what they say makes untrue.")
    public let noLongerTrue: [MemoryExtractionEnding]
}

extension MemoryExtractionReport {
    /// It as the proposal it is: nothing in it checked.
    var proposal: MemoryProposal {
        MemoryProposal(
            facts: memories.map {
                MemoryProposal.Fact(path: $0.path, value: $0.value, quote: $0.quote, confidence: $0.confidence)
            },
            endings: noLongerTrue.map { MemoryProposal.Ending(line: $0.line, quote: $0.quote) }
        )
    }
}

/// Runs one background extraction pass: renders the user messages under
/// consideration as a transcript, with the person's memory as it is, asks the
/// model for the typed extraction report, and returns it.
public enum MemoryExtractionService {
    /// Task instructions that are not field requirements belong here; the
    /// generated schema carries the report and field descriptions.
    private static let task = """
        Find what the person says about themselves that matters in later conversations: who they \
        are, where they live, what they like, the people they know, their habits. A request to \
        make or do something is not about them. Assistant replies are only context. Put each at a \
        path in their memory, under the names it already has. When what they say makes a line of \
        their memory untrue, even without saying so, give that line. Return empty lists when they \
        say nothing about themselves.
        """

    public static func extract(
        endpoint: any ModelEndpoint,
        observations: [MemoryObservation],
        remembered: [MemoryFact]
    ) async throws -> MemoryExtractionReport {
        let lines = MemoryTree(remembered).facts.map(\.line)
        let memory = lines.isEmpty ? "Their memory is empty." : "Their memory now:\n" + lines.joined(separator: "\n")
        let entries: [Transcript.Entry] = [
            .instructions(
                .init(
                    segments: [.text(.init(content: task))],
                    toolDefinitions: []
                )
            ),
            .prompt(.init(segments: [.text(.init(content: memory + "\n\n" + transcript(observations)))])),
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

    /// The background pass runs after the conversation goes quiet: it asks for
    /// a proposal for pending exchanges, and User reads it into their memory,
    /// with the write-time generation and latest-source guards.
    public static func extractAndCommit(
        endpoint: any ModelEndpoint,
        actorSystem: ClusterSystem,
        user: User,
        expectedLatestSourceID: MemorySourceID
    ) async throws -> ExtractionOutcome {
        let snapshot = try await user.extractionSnapshot()
        guard snapshot.latestObservationSourceID == expectedLatestSourceID else { return .stale }
        guard !snapshot.input.observations.isEmpty else { return .alreadyHandled }

        let report = try await extract(
            endpoint: endpoint, observations: snapshot.input.chronologicalObservations,
            remembered: snapshot.input.existingFacts)

        // Keep the input and generation captured before the model call so a
        // concurrent forget cannot associate this report with a new generation.
        let outcome = try await user.commitExtraction(
            snapshot.input,
            proposal: report.proposal,
            expectedLatestSourceID: expectedLatestSourceID
        )
        if case .committed(let changes, let rejected) = outcome {
            let metadata: Logger.Metadata = [
                "observations": "\(snapshot.input.observations.count)",
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

    static func transcript(_ observations: [MemoryObservation]) -> String {
        observations.enumerated().flatMap { index, observation in
            var exchange = ["user [\(index + 1)]: \(observation.text)"]
            if let response = observation.response {
                exchange.append("assistant [\(index + 1)]: \(response)")
            }
            return exchange
        }.joined(separator: "\n")
    }
}

extension MemoryExtractionService {
    public enum EndpointError: Error, Equatable, Sendable {
        /// Memory names no model to extract with.
        case notConfigured
    }

    /// The model a pass extracts with, as `configuration` names it, from the node's `endpoints`.
    static func endpoint(
        for configuration: MemoryExtractionConfiguration, from endpoints: AgentModelEndpointFactory
    ) async throws -> any ModelEndpoint {
        guard case .configured(let provider, let ollamaKeepAlive) = configuration.provider else {
            throw EndpointError.notConfigured
        }
        let reasoning: ReasoningEffortSelection? =
            switch configuration.model.provider {
            case .ollama, .gemini:
                .init(effort: .none, encoding: .disabled)
            default:
                nil
            }
        return try await endpoints.endpoint(
            model: configuration.model,
            configuration: provider,
            temperature: 0.2,
            ollamaKeepAlive: ollamaKeepAlive,
            reasoning: reasoning
        )
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
