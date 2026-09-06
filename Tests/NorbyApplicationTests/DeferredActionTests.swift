import NorbyApplication
import Testing

struct DeferredActionTests {
    @Test
    func notifyPreservesTheFinalMessage() {
        let action = DeferredAction(kind: .notify, content: "Call mom")

        #expect(action == .notify(message: "Call mom"))
        #expect(action.content == "Call mom")
    }

    @Test
    func promptAgentPreservesTheInstruction() {
        let action = DeferredAction(kind: .promptAgent, content: "Check the weather")

        #expect(action == .promptAgent(instruction: "Check the weather"))
        #expect(action.content == "Check the weather")
    }

}
