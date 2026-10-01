import AnyLanguageModel
import DistributedCluster
import DurableWorkflows
import Hail
import TurgaiDomain
import TurgaiMemory

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// The background memory-extraction report. One instance is generated per
/// extraction pass over a slice of conversation history; the User aggregate
/// reconciles every candidate against its durable observations, so a
/// candidate whose supportingText does not match a user message verbatim is
/// rejected there, not here.
@Generable(
    description: "Candidate memories grounded in user-provided information."
)
public struct MemoryExtractionReport: Codable, Sendable {
    @Generable
    public struct MemoryExtractionCandidate: Codable, Sendable {
        @Guide(
            description: "Fact group. Use exactly one of: profile, preference, relationship, project, environment.",
            .anyOf(["profile", "preference", "relationship", "project", "environment"])
        )
        public let namespace: String
        @Guide(description: "A short stable attribute name for the fact, e.g. drinksCoffee or school")
        public let predicate: String
        @Guide(description: "The fact's content, in the form valueKind describes")
        public let value: String
        @Guide(
            description: "The value's form. Use exactly one of: text, person, place, date, preference.",
            .anyOf(["text", "person", "place", "date", "preference"])
        )
        public let valueKind: String
        @Guide(description: "Certainty the fact is true, between 0 and 1")
        public let confidence: Double
        @Guide(description: "How much the fact matters for future conversations, between 0 and 1")
        public let importance: Double
        @Guide(
            description:
                "How likely the fact is to change. Use exactly one of: transient, situational, mutable, stable.",
            .anyOf(["transient", "situational", "mutable", "stable"])
        )
        public let stability: String
        @Guide(
            description:
                "A short verbatim quote copied from the user's own message. Facts without a verbatim quote that matches the conversation are rejected, so never paraphrase."
        )
        public let supportingText: String
    }

    public let memories: [MemoryExtractionCandidate]
}

/// Runs one background extraction pass: renders the user messages under
/// consideration as a transcript, asks the model for the typed extraction
/// report, and returns it. Runs on a dedicated endpoint whose context window
/// is sized for the task; the window, not an output cap, bounds the report.
public enum MemoryExtractionService {
    /// Task instructions that are not field requirements belong here; the
    /// generated schema carries the report and field descriptions.
    private static let task = """
        Extract user-provided information that may help future conversations,
        including brief answers understood from the assistant's question. Use
        assistant replies only as context; ground every fact in user text. Return
        an empty memories list when nothing useful is supported.
        """

    public static func extract(
        endpoint: any ModelEndpoint,
        observations: [MemoryObservation]
    ) async throws -> MemoryExtractionReport {
        let entries: [Transcript.Entry] = [
            .instructions(
                .init(
                    segments: [.text(.init(content: task))],
                    toolDefinitions: []
                )
            ),
            .prompt(.init(segments: [.text(.init(content: transcript(observations)))])),
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
        let report = try await extract(endpoint: endpoint, observations: evidence)

        // Keep the input and generation captured before the model call so a
        // concurrent forget cannot associate this report with a new generation.
        let proposals = report.memories.compactMap { candidate in
            proposal(
                from: candidate,
                evidence: evidence
            )
        }
        let rejected = report.memories.count - proposals.count
        if rejected > 0 {
            actorSystem.log.warning(
                "Memory extraction rejected candidates",
                metadata: [
                    "returned": "\(report.memories.count)",
                    "kept": "\(proposals.count)",
                    "rejectedQuotes": .string(
                        report.memories.map(\.supportingText).joined(separator: " | ")
                    ),
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
            proposals: proposals,
            expectedLatestSourceID: expectedLatestSourceID
        )
    }

    /// Maps one model candidate to a concrete proposal. Validation, not
    /// trust: the supporting quote must match exactly one stored observation
    /// verbatim, identifiers must parse, and values must coerce. Candidates
    /// that fail are dropped here, before User ever sees them.
    static func proposal(
        from candidate: MemoryExtractionReport.MemoryExtractionCandidate,
        evidence: [MemoryObservation]
    ) -> MemoryProposal? {
        let quote = normalize(candidate.supportingText)
        guard !quote.isEmpty else { return nil }
        let predicate = candidate.predicate.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawValue = candidate.value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !predicate.isEmpty, !rawValue.isEmpty,
            predicate.count <= 500, rawValue.count <= 500
        else { return nil }
        let matchingSources = evidence.filter { normalize($0.text).contains(quote) }
        let matchingSourceIDs = Set(matchingSources.map(\.sourceID))
        guard matchingSourceIDs.count == 1,
            let sourceID = matchingSourceIDs.first,
            let source = matchingSources.first(where: { $0.sourceID == sourceID }),
            let namespace = MemoryNamespace(rawValue: candidate.namespace),
            let stability = MemoryStability(rawValue: candidate.stability)
        else { return nil }

        let value: MemoryValue
        switch candidate.valueKind {
        case "text": value = .text(rawValue)
        case "person": value = .person(rawValue)
        case "place": value = .place(rawValue)
        case "date":
            guard let date = ISO8601DateFormatter().date(from: rawValue) else { return nil }
            value = .date(date)
        case "preference":
            guard let preference = Bool(rawValue) else { return nil }
            value = .preference(preference)
        default: return nil
        }

        let fact = FactCandidate(
            namespace: namespace,
            predicate: predicate,
            value: value,
            evidence: [source.id],
            supportingText: candidate.supportingText,
            confidence: candidate.confidence,
            importance: candidate.importance,
            stability: stability,
            observedAt: source.observedAt
        )
        return .add(fact)
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

/// Durable delay and retry boundary for one completed user exchange.
public struct MemoryExtractionWorkflowInput: Codable, Sendable {
    public let userID: TurgaiDomain.UserID
    public let observation: MemoryObservation
    public let configuration: MemoryExtractionConfiguration
    public let fireAt: Date

    public init(
        userID: TurgaiDomain.UserID,
        observation: MemoryObservation,
        configuration: MemoryExtractionConfiguration,
        fireAt: Date
    ) {
        self.userID = userID
        self.observation = observation
        self.configuration = configuration
        self.fireAt = fireAt
    }
}

@Workflow
public struct MemoryExtractionWorkflow {
    public typealias Input = MemoryExtractionWorkflowInput
    public typealias Output = DurableVoid
    public typealias Activities = MemoryExtractionActivities

    public static let retryPolicy = RetryPolicy(
        initialInterval: .seconds(5),
        backoffCoefficient: 2,
        maximumInterval: .seconds(300),
        maximumAttempts: 6
    )

    public init() {}

    public func run(input: Input, context: WorkflowContext) async throws -> Output {
        try await context.sleep(until: input.fireAt, summary: "memory extraction quiet period")
        return try await context.executeActivity(
            MemoryExtractionActivities.Activities.Extract.self,
            input: input
        )
    }

    public static func id(userID: TurgaiDomain.UserID, sourceID: MemorySourceID) -> WorkflowID {
        let identity = "memory-extraction:\(userID.rawValue):\(sourceID.rawValue.uuidString)"
        return WorkflowID(
            rawValue: "memory-extraction-\(turgaiDeterministicUUID(identity).uuidString)"
        )
    }
}

@ActivityContainer
public struct MemoryExtractionActivities {
    private let endpointFactory: AgentModelEndpointFactory

    public init(endpointFactory: AgentModelEndpointFactory) {
        self.endpointFactory = endpointFactory
    }

    @Activity
    public func extract(
        input: MemoryExtractionWorkflowInput,
        context: ActivityContext
    ) async throws -> DurableVoid {
        let user = try await User.resolve(on: context.system, userID: input.userID)
        // This idempotent write closes the gap between durable workflow
        // acceptance and Conversation's immediate observation write.
        try await user.recordObservation(input.observation)

        guard case .configured(let provider, let ollamaKeepAlive) = input.configuration.provider else {
            return DurableVoid()
        }
        let reasoning: ReasoningEffortSelection? =
            switch input.configuration.model.provider {
            case .ollama, .gemini:
                .init(effort: .none, encoding: .disabled)
            default:
                nil
            }
        let endpoint = try await endpointFactory.endpoint(
            model: input.configuration.model,
            configuration: provider,
            temperature: 0.2,
            ollamaKeepAlive: ollamaKeepAlive,
            reasoning: reasoning
        )

        _ = try await MemoryExtractionService.extractAndCommit(
            endpoint: endpoint,
            actorSystem: context.system,
            user: user,
            expectedLatestSourceID: input.observation.sourceID
        )
        return DurableVoid()
    }
}
