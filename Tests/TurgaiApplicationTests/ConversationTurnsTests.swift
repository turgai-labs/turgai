import AnyLanguageModel
import Foundation
import Hail
import Testing
import TurgaiDomain

@testable import TurgaiApplication

struct ConversationTurnsTests {
    /// Each message starts a turn; its tool calls and results are the steps, and the reply or
    /// the failure ends it.
    @Test
    func transcriptFoldsIntoTurns() {
        let at = { (seconds: TimeInterval) in Date(timeIntervalSince1970: seconds) }
        let call = ToolCall(id: "1", name: "objects_find", arguments: GeneratedContent(properties: ["name": "Ann"]))
        let transcript: [ChatMessage] = [
            .text(sender: "user", content: "find Ann", timestamp: at(1)),
            .toolCall(calls: [call], timestamp: at(2)),
            .toolResult(id: "1", name: "objects_find", output: .text("ann"), timestamp: at(3)),
            .response(sender: "agent", content: GeneratedContent("Found her."), timestamp: at(4)),
            .text(sender: "user", content: "ask Bob", timestamp: at(5)),
            .toolResult(id: "2", name: "objects_invoke", output: .text("no bob"), failure: .rejected, timestamp: at(6)),
            .text(sender: "user", content: "still there?", timestamp: at(7)),
        ]

        let turns = ConversationTurns.fold(transcript)

        #expect(turns.map(\.message) == ["find Ann", "ask Bob", "still there?"])
        #expect(turns[0].steps.count == 2)
        #expect(turns[0].outcome == .replied("Found her.", at: at(4)))
        guard case .toolFinished("objects_invoke", "no bob", "rejected", _) = turns[1].steps.first else {
            Issue.record("Expected a failed step, got \(turns[1].steps)")
            return
        }
        #expect(turns[1].outcome == .running)
        #expect(turns[2].steps.isEmpty)
    }
}
