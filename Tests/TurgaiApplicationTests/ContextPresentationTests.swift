import Hail
import Testing

@testable import TurgaiConversations

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

struct ContextPresentationTests {
    @Test("renders phase, context window, and usage in readable form")
    func rendersFullSnapshot() {
        let snapshot = AgentContextSnapshot(
            agentID: AgentID(role: Role("conversation"), contextID: AgentContextID("telegram:1")),
            state: .executingTool,
            contextUsage: ContextUsage(usedTokens: 6_429, limitTokens: 16_384, source: .reported),
            usageSummary: AgentUsageSummary(
                requestCount: 4,
                inputTokens: 19_021,
                outputTokens: 311,
                reasoningTokens: 120,
                totalTokens: 19_332
            ),
            historyTurnCount: 9,
            hasContextSummary: true
        )

        let text = ContextPresentation.text(for: snapshot)

        #expect(text.contains("Status: executingTool"))
        #expect(text.contains("Context window: 6,429 / 16,384 tokens (39%, reported by the model)"))
        #expect(text.contains("Turns in context: 9"))
        #expect(text.contains("Compaction summary: yes"))
        #expect(text.contains("Requests: 4"))
        #expect(text.contains("Input tokens: 19,021"))
        #expect(text.contains("Reasoning tokens: 120"))
        #expect(text.contains("Total tokens: 19,332"))
    }

    @Test("omits the usage section and unknown values when nothing was reported")
    func rendersEmptySnapshot() {
        let snapshot = AgentContextSnapshot(
            agentID: AgentID(role: Role("conversation"), contextID: AgentContextID("telegram:1")),
            state: .idle
        )

        let text = ContextPresentation.text(for: snapshot)

        #expect(text.contains("Status: idle"))
        #expect(text.contains("Context window: not reported"))
        #expect(text.contains("Turns in context: 0"))
        #expect(!text.contains("Model usage"))
    }
}
