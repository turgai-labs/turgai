import AnyLanguageModel
import DistributedCluster
import Hail
import TurgaiDomain
import TurgaiMemory

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// What one extraction pass found the person said about themselves. The User
/// aggregate reconciles every candidate against its durable observations, so a
/// candidate whose quote does not match a user message verbatim is rejected.
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

    public let memories: [MemoryExtractionCandidate]
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
        path in their memory, under the names it already has. Return an empty list when they say \
        nothing about themselves.
        """

    public static func extract(
        endpoint: any ModelEndpoint,
        observations: [MemoryObservation],
        remembered: MemoryTree
    ) async throws -> MemoryExtractionReport {
        let memory =
            remembered.isEmpty ? "Their memory is empty." : "Their memory now:\n" + remembered.rendered(root: "They")
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

    /// The background pass runs after the conversation goes quiet: it extracts
    /// candidates for pending exchanges, validates them against the captured
    /// batch and its context, then commits the result. User owns the write-time
    /// generation and latest-source guards.
    public static func extractAndCommit(
        endpoint: any ModelEndpoint,
        actorSystem: ClusterSystem,
        user: User,
        expectedLatestSourceID: MemorySourceID
    ) async throws -> ExtractionOutcome {
        let snapshot = try await user.extractionSnapshot()
        guard snapshot.latestObservationSourceID == expectedLatestSourceID else { return .stale }
        guard !snapshot.input.observations.isEmpty else { return .alreadyHandled }

        let evidence = snapshot.input.chronologicalObservations
        let report = try await extract(
            endpoint: endpoint, observations: evidence, remembered: MemoryTree(snapshot.input.existingFacts))

        // Keep the input and generation captured before the model call so a
        // concurrent forget cannot associate this report with a new generation.
        let candidates = report.memories.compactMap { candidate in
            Self.candidate(from: candidate, evidence: evidence)
        }
        let rejected = report.memories.count - candidates.count
        if rejected > 0 {
            actorSystem.log.warning(
                "Memory extraction rejected candidates",
                metadata: [
                    "returned": "\(report.memories.count)",
                    "kept": "\(candidates.count)",
                    "rejectedQuotes": .string(report.memories.map(\.quote).joined(separator: " | ")),
                ]
            )
        } else {
            actorSystem.log.info(
                "Memory extraction pass",
                metadata: [
                    "observations": "\(snapshot.input.observations.count)",
                    "candidates": "\(report.memories.count)",
                ]
            )
        }
        return try await user.commitExtraction(
            snapshot.input,
            candidates: candidates,
            expectedLatestSourceID: expectedLatestSourceID
        )
    }

    /// Maps one model candidate to a concrete one. Validation, not trust: the quote must match
    /// exactly one stored observation verbatim, the path must be one, and the value must be
    /// written. Candidates that fail are dropped here, before User ever sees them.
    static func candidate(
        from candidate: MemoryExtractionReport.MemoryExtractionCandidate,
        evidence: [MemoryObservation]
    ) -> FactCandidate? {
        let quote = normalize(candidate.quote)
        let value = candidate.value.trimmed()
        guard !quote.isEmpty, !value.isEmpty, value.count <= 500,
            let path = MemoryPath(candidate.path),
            path.names.allSatisfy({ $0.rawValue.count <= 100 })
        else { return nil }
        let matchingSources = evidence.filter { normalize($0.text).contains(quote) }
        let matchingSourceIDs = Set(matchingSources.map(\.sourceID))
        guard matchingSourceIDs.count == 1,
            let sourceID = matchingSourceIDs.first,
            let source = matchingSources.first(where: { $0.sourceID == sourceID })
        else { return nil }
        return FactCandidate(
            path: path,
            value: value,
            evidence: [source.id],
            supportingText: candidate.quote,
            confidence: candidate.confidence,
            observedAt: source.observedAt
        )
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

    private static func normalize(_ value: String) -> String {
        // Punctuation-tolerant: models quote loosely ("mornings," vs
        // "mornings"), so matching ignores case, punctuation, and spacing.
        value
            .lowercased()
            .filter { $0.isLetter || $0.isNumber || $0.isWhitespace }
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
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
                guard case .committed(let update) = try await extract() else { return false }
                return update.shouldNotify
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
