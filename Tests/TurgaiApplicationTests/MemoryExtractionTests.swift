import Foundation
import Testing
import TurgaiDomain
import TurgaiMemory

@testable import TurgaiApplication

/// What the extractor is shown of a conversation.
struct MemoryExtractionTests {
    private let check = ConversationID(stableKey: "turgai:check")!

    private func exchange(_ text: String, response: String? = nil) -> MemoryObservation {
        MemoryObservation(
            sourceID: MemorySourceID(), conversation: check, heardBy: AgentProfileID("turgai"), text: text,
            response: response, observedAt: Date())
    }

    /// Exchanges read already are context, unnumbered; the new ones are numbered from 1, each reply
    /// beside what it answers, so a short answer keeps its question.
    @Test
    func theNewExchangesAreNumberedAfterTheEarlierOnes() {
        let input = ExtractionInput(
            conversation: check,
            earlier: [exchange("Weather in Haar, Germany?", response: "Rain all week.")],
            new: [
                exchange("Where I'm living?", response: "I don't know. Want to tell me?"), exchange("Haar"),
            ],
            generation: .initial, existingFacts: [])

        #expect(
            MemoryExtractionService.transcript(input) == """
                Earlier in this conversation, read already:
                user: Weather in Haar, Germany?
                assistant: Rain all week.

                New:
                user [1]: Where I'm living?
                assistant [1]: I don't know. Want to tell me?
                user [2]: Haar
                """)
    }

    /// With nothing read yet, there's nothing earlier.
    @Test
    func aConversationReadForTheFirstTimeHasNoEarlierPart() {
        let input = ExtractionInput(
            conversation: check, new: [exchange("Haar", response: "Got it.")], generation: .initial, existingFacts: [])

        #expect(MemoryExtractionService.transcript(input) == "New:\nuser [1]: Haar\nassistant [1]: Got it.")
    }
}
