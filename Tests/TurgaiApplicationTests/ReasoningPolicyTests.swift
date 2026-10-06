import Hail
import Testing
import TurgaiHail

struct ReasoningPolicyTests {
    private func context(
        rounds: Int, last: ToolRoundOutcome?, tools: Bool = true, purpose: ModelRequestPurpose = .generation
    ) -> ModelReasoningContext {
        ModelReasoningContext(
            model: "qwen3.5:9b", purpose: purpose, hasTools: tools, completedToolRounds: rounds, lastToolRound: last)
    }

    /// It thinks to decide: on the first round, and after a failure; it doesn't to carry on.
    @Test
    func itThinksWhenDecidingNotWhenExecuting() {
        #expect(ReasoningPolicy.thinkWhenDeciding(context(rounds: 0, last: nil)) == .enabled)
        #expect(ReasoningPolicy.thinkWhenDeciding(context(rounds: 1, last: .succeeded)) == .disabled)
        #expect(ReasoningPolicy.thinkWhenDeciding(context(rounds: 2, last: .failed)) == .enabled)
        #expect(ReasoningPolicy.thinkWhenDeciding(context(rounds: 0, last: nil, tools: false)) == .providerDefault)
        #expect(
            ReasoningPolicy.thinkWhenDeciding(context(rounds: 0, last: nil, purpose: .compaction(maxOutputTokens: 100)))
                == .providerDefault)
    }
}
