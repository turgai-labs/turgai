import AnyLanguageModel
import DistributedCluster
import Hail
import NorbyDomain
import NorbyMemory

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
    description: "Durable memory extraction for a personal-assistant conversation.\n\nExtract durable memories about the user into memories: facts worth remembering across conversations, such as preferences, personal details, and ongoing plans. Only extract what the conversation actually supports; do not invent facts. supportingText must be a short verbatim quote from the user's own message; facts without a matching verbatim quote are rejected, so never paraphrase. Small talk and one-off questions need no memory; leave memories empty rather than filling it."
)
public struct MemoryExtractionReport: Codable, Sendable {
    @Generable
    public struct MemoryExtractionCandidate: Codable, Sendable {
        @Guide(description: "Fact group: profile, preference, relationship, project, or environment")
        public let namespace: String
        @Guide(description: "A short stable attribute name for the fact, e.g. drinksCoffee or school")
        public let predicate: String
        @Guide(description: "The fact's content, in the form valueKind describes")
        public let value: String
        @Guide(description: "The value's form: text, person, place, date (ISO8601), or preference (true or false)")
        public let valueKind: String
        @Guide(description: "Certainty the fact is true, between 0 and 1")
        public let confidence: Double
        @Guide(description: "How much the fact matters for future conversations, between 0 and 1")
        public let importance: Double
        @Guide(description: "How likely the fact is to change: transient, situational, mutable, or stable")
        public let stability: String
        @Guide(
            description: "A short verbatim quote copied from the user's own message. Facts without a verbatim quote that matches the conversation are rejected, so never paraphrase."
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
    /// Mirrors the report type's own description: this prose is the prompt,
    /// the type is the contract.
    private static let task = """
        You are extracting durable memories about the user from a conversation. \
        Extract durable memories into memories: facts worth remembering across \
        conversations, such as preferences, personal details, and ongoing plans. \
        Only extract what the conversation actually supports; do not invent facts. \
        supportingText must be a short verbatim quote from the user's own \
        message; facts without a matching verbatim quote are rejected, so never \
        paraphrase. Small talk and one-off questions need no memory; leave \
        memories empty rather than filling it.

        The messages follow.
        """

    public static func extract(
        endpoint: any ModelEndpoint,
        messages: [String]
    ) async throws -> MemoryExtractionReport {
        var transcript: [String] = []
        for (index, message) in messages.enumerated() {
            transcript.append("user [\(index + 1)]: \(message)")
        }
        let entries: [Transcript.Entry] = [
            .instructions(
                .init(
                    segments: [.text(.init(content: task))],
                    toolDefinitions: []
                )
            ),
            .prompt(.init(segments: [.text(.init(content: transcript.joined(separator: "\n")))])),
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

    /// The full background pass Conversation schedules after the
    /// conversation goes quiet: extract candidates for everything
    /// accumulated since the last pass, validate them against the user's
    /// durable evidence, and commit the concrete proposals. The pending
    /// observation set is the accumulator, so the batch is read here, not
    /// threaded through callers. User keeps only the write-time guards;
    /// everything that interprets a candidate lives here.
    public static func extractAndCommit(
        endpoint: any ModelEndpoint,
        actorSystem: ClusterSystem,
        userID: NorbyDomain.UserID
    ) async throws -> ExtractionOutcome {
        let user = try await User.resolve(on: actorSystem, userID: userID)
        let pending = try await user.extractionSnapshot().input.observations
        guard !pending.isEmpty else { return .alreadyHandled }

        let report = try await extract(endpoint: endpoint, messages: pending.map(\.text))

        // Re-read after the model call: turns that completed meanwhile added
        // observations. The fresh snapshot is what the write-time guards
        // validate against; anything newer simply stays pending for the
        // next pass.
        let snapshot = try await user.extractionSnapshot()
        guard !snapshot.input.observations.isEmpty else { return .alreadyHandled }
        let evidence = snapshot.evidence + snapshot.input.observations
        let proposals = report.memories.compactMap { candidate in
            proposal(
                from: candidate,
                evidence: evidence,
                observedAt: snapshot.input.observations.last?.observedAt
            )
        }
        return try await user.commitExtraction(snapshot.input, proposals: proposals)
    }

    /// Maps one model candidate to a concrete proposal. Validation, not
    /// trust: the supporting quote must match exactly one stored observation
    /// verbatim, identifiers must parse, and values must coerce. Candidates
    /// that fail are dropped here, before User ever sees them.
    static func proposal(
        from candidate: MemoryExtractionReport.MemoryExtractionCandidate,
        evidence: [MemoryObservation],
        observedAt: Date?
    ) -> MemoryProposal? {
        let quote = normalize(candidate.supportingText)
        guard !quote.isEmpty else { return nil }
        let predicate = candidate.predicate.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawValue = candidate.value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !predicate.isEmpty, !rawValue.isEmpty,
            predicate.count <= 500, rawValue.count <= 500
        else { return nil }
        let matches = evidence.filter { normalize($0.text).contains(quote) }
        guard matches.count == 1, let source = matches.first,
            let namespace = MemoryNamespace(rawValue: candidate.namespace),
            let stability = MemoryStability(rawValue: candidate.stability),
            let observedAt
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
            observedAt: observedAt
        )
        return .add(fact)
    }

    private static func normalize(_ value: String) -> String {
        value.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}
