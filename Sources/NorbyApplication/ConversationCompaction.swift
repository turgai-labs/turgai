import AnyLanguageModel
import Hail

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// The one report generated when Hail compacts a conversation. The summary is
/// the only part projected into future model context; candidates remain
/// application-owned data and are reconciled against the User actor.
@Generable(
    description: "The durable compaction report for a personal-assistant conversation.\n\nProduce two summary sections. summary.keyPoints holds stable facts and decisions needed to continue the conversation. summary.openThreads holds unresolved questions or tasks that still matter. Be concise; drop small talk and superseded details.\n\nAlso extract durable memories about the user into memories: facts worth remembering across conversations, such as preferences, personal details, and ongoing plans. Only extract what the conversation actually supports; do not invent facts. supportingText must be a short verbatim quote from the user's own message; facts without a matching verbatim quote are rejected, so never paraphrase. Small talk and one-off questions need no memory; leave memories empty rather than filling it."
)
public struct ConversationCompactionReport: Codable, Sendable {
    public let summary: ConversationCompactionSummary
    public let memories: [ConversationCompactionMemoryCandidate]
}

@Generable
public struct ConversationCompactionSummary: Codable, Sendable {
    @Guide(description: "Stable facts and decisions needed to continue the conversation")
    public let keyPoints: [String]
    @Guide(description: "Unresolved questions or tasks that still matter")
    public let openThreads: [String]
}

// Formerly ConversationCompactionReport.MemoryCandidate; renamed during the no-nested-Generable sweep.
@Generable
public struct ConversationCompactionMemoryCandidate: Codable, Sendable {
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

/// The host-side adapter for Hail's single compaction operation. The model is
/// asked for `ConversationCompactionReport` once; Hail receives only its
/// structured representation for persistence and context projection.
public enum NorbyCompactionOperation {
    public static func make() -> CompactionOperation {
        CompactionOperation(
            stream: { endpoint, request, authority in
                AsyncStream { continuation in
                    let task = Task {
                        for await event in endpoint.stream(
                            request: ModelRequest(input: request, entries: request.entries),
                            tools: [],
                            authority: authority,
                            generating: ConversationCompactionReport.self,
                            purpose: .compaction(maxOutputTokens: request.maxOutputTokens)
                        ) {
                            switch event {
                            case .activity(let activity):
                                continuation.yield(.activity(activity))
                            case .partialUpdated(let value):
                                continuation.yield(.partialUpdated(value.generatedContent))
                            case .usage(let usage):
                                continuation.yield(.usage(usage))
                            case .contextUsage(let usage):
                                continuation.yield(.contextUsage(usage))
                            case .generated(let value):
                                continuation.yield(.generated(value.generatedContent))
                            case .failed(let error):
                                continuation.yield(.failed(error))
                            case .toolsRequested:
                                continuation.yield(
                                    .failed(.invalidResponse("Compaction report requested a tool call."))
                                )
                            }
                        }
                        continuation.finish()
                    }
                    continuation.onTermination = { _ in task.cancel() }
                }
            },
            contextProjection: {
                (generated: GeneratedContent, budget: ContextProjectionBudget) throws(AgentRuntimeError)
                    -> GeneratedContent in
                do {
                    let report = try ConversationCompactionReport(generated)
                    // A schema-valid report can still be semantically empty
                    // (observed from a small model under a tight output
                    // budget). Archiving entries into an empty summary is
                    // silent history loss, so the projection refuses it and
                    // the runtime retries or continues un-compacted.
                    guard !report.summary.keyPoints.isEmpty || !report.summary.openThreads.isEmpty else {
                        throw AgentRuntimeError.modelMisbehavior(
                            "Compaction report carried an empty summary"
                        )
                    }
                    return fitSummary(report.summary, budget: budget)
                } catch let error as AgentRuntimeError {
                    throw error
                } catch {
                    throw AgentRuntimeError.modelMisbehavior(
                        "Compaction report did not contain a valid conversation summary: \(error)"
                    )
                }
            }
        )
    }

    /// Trims the projected summary deterministically so the rebuilt request
    /// fits, without a second model call. Open threads are dropped before key
    /// points; only the last resort is a raw character cap.
    private static func fitSummary(
        _ summary: ConversationCompactionSummary,
        budget: ContextProjectionBudget
    ) -> GeneratedContent {
        let charsPerToken = 4
        let maxChars = budget.availableTokens * charsPerToken

        var keyPoints = summary.keyPoints
        var openThreads = summary.openThreads

        func estimatedTokens() -> Int {
            (keyPoints + openThreads).joined(separator: "\n").count / charsPerToken
        }

        while !openThreads.isEmpty && estimatedTokens() > budget.availableTokens {
            openThreads.removeLast()
        }
        while keyPoints.count > 1 && estimatedTokens() > budget.availableTokens {
            keyPoints.removeLast()
        }

        var text = (keyPoints + openThreads).joined(separator: "\n")
        if text.count > maxChars {
            let prefix = text.prefix(maxChars)
            if let lastBreak = prefix.lastIndex(of: "\n") {
                text = String(prefix[..<lastBreak])
            } else {
                text = String(prefix)
            }
        }
        return GeneratedContent(text)
    }
}
