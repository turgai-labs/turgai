import AnyLanguageModel
import Hail

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
}
