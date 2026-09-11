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
@Generable
public struct ConversationCompactionReport: Codable, Sendable {
    @Generable
    public struct Summary: Codable, Sendable {
        @Guide(description: "Stable facts and decisions needed to continue the conversation")
        public let keyPoints: [String]
        @Guide(description: "Unresolved questions or tasks that still matter")
        public let openThreads: [String]
    }

    @Generable
    public struct MemoryCandidate: Codable, Sendable {
        @Guide(description: "add for a new fact, revise when correcting an existing fact")
        public let operation: String
        public let factID: String?
        public let namespace: String
        public let predicate: String
        public let value: String
        public let valueKind: String
        public let confidence: Double
        public let importance: Double
        public let stability: String
        @Guide(description: "A short quote copied from the user's supporting message")
        public let supportingText: String
    }

    public let summary: Summary
    public let memories: [MemoryCandidate]
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
        _ summary: ConversationCompactionReport.Summary,
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
