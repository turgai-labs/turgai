import AnyLanguageModel
import Hail
import Testing
import TurgaiDomain
import TurgaiHail

@testable import TurgaiConversations

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// What the agent did in a conversation's turns, read from the agent's journal.
struct ConversationTurnsTests {
    private func input(_ text: String, at seconds: TimeInterval) -> AgentHistory.Input {
        AgentHistory.Input(content: GeneratedContent(text), at: Date(timeIntervalSince1970: seconds))
    }

    private func reply(_ text: String, at seconds: TimeInterval) -> AgentEvent {
        .history(
            .replied(AgentHistory.Reply(content: GeneratedContent(text), at: Date(timeIntervalSince1970: seconds))))
    }

    /// Each turn the conversation linked comes back under the conversation's id, with its steps,
    /// even one a compaction folded away; one it never linked, as a rerun after a restart leaves,
    /// isn't one of its turns.
    @Test
    func linkedTurnsComeBackUnderTheConversationsIds() throws {
        let call = ToolCall(id: "call-1", name: "weather", arguments: GeneratedContent(properties: [:]))
        let result = ToolResult(toolCallID: "call-1", name: "weather", output: .text("fog"))
        let first = TurgaiDomain.TurnID()
        let second = TurgaiDomain.TurnID()
        let events: [AgentEvent] = [
            .history(.received(input("weather?", at: 1), turn: Hail.TurnID("a1"))),
            .history(.called(call, at: Date(timeIntervalSince1970: 2))),
            .history(.resulted(result, at: Date(timeIntervalSince1970: 3))),
            reply("Foggy.", at: 4),
            .history(.received(input("thanks", at: 5), turn: Hail.TurnID("a2"))),
            .history(.interrupted(at: Date(timeIntervalSince1970: 6))),
            .history(.received(input("thanks", at: 7), turn: Hail.TurnID("a3"))),
            reply("Anytime.", at: 8),
            .history(
                .compacted(
                    .init(context: GeneratedContent("s"), report: GeneratedContent("s")),
                    through: .after(Hail.TurnID("a1")),
                    kept: .all)),
        ]

        let turns = try ConversationTurns.turns(
            from: events, links: [AgentTurnID(rawValue: "a1"): first, AgentTurnID(rawValue: "a3"): second])

        #expect(turns.map(\.id) == [first, second])
        #expect(turns.first?.message == "weather?")
        #expect(turns.first?.steps.count == 2)
        #expect(turns.first?.outcome == .replied("Foggy.", at: Date(timeIntervalSince1970: 4)))
        #expect(turns.last?.outcome == .replied("Anytime.", at: Date(timeIntervalSince1970: 8)))
    }
}
