import AnyLanguageModel
import Foundation
import Testing
import TurgaiDomain
import TurgaiMemory

@testable import TurgaiApplication

/// What the extractor is given of a conversation, and what it answers.
struct MemoryExtractionTests {
    private let check = ConversationID(stableKey: "turgai:check")!

    private func exchange(_ text: String, response: String? = nil) -> MemoryObservation {
        MemoryObservation(
            sourceID: MemorySourceID(), conversation: check, heardBy: AgentProfileID("turgai"), text: text,
            response: response, observedAt: Date())
    }

    /// It's given their memory, each fact numbered; the exchanges read already, as they were; and the
    /// new ones numbered from 1, each reply beside what it answers, so a short answer keeps its
    /// question, and none when there was none.
    @Test
    func itIsGivenTheirMemoryAndTheNewExchangesNumbered() {
        let haar = MemoryFact(
            relation: .livesIn, to: MemoryName("Haar")!, learned: Said(observation: ObservationID(), at: Date()))
        let input = ExtractionInput(
            conversation: check,
            earlier: [exchange("Weather in Haar, Germany?", response: "Rain all week.")],
            new: [
                exchange("Where I'm living?", response: "I don't know. Want to tell me?"), exchange("Haar"),
            ],
            generation: .initial, existingFacts: [haar])

        #expect(
            MemoryPassInput(input).generatedContent.jsonString
                == #"{"memory":[{"fact":1,"relation":"livesIn","to":"Haar"}],"#
                + #""earlier":[{"person":"Weather in Haar, Germany?","assistant":"Rain all week."}],"#
                + #""new":[{"exchange":1,"person":"Where I'm living?","assistant":"I don't know. Want to tell me?"},"#
                + #"{"exchange":2,"person":"Haar"}]}"#)
    }

    /// Its answer is a relation from the list for each fact learned, and a fact's number for each
    /// ended; a relation not on the list isn't one.
    @Test
    func itAnswersWithRelationsFromTheList() throws {
        let answer =
            #"{"learned":[{"relation":"livesIn","to":"Haar","exchange":1}],"#
            + #""ended":[{"fact":2,"exchange":1}]}"#
        let report = try MemoryReport(GeneratedContent(json: answer))

        #expect(
            report.proposal
                == MemoryProposal(
                    facts: [.init(relation: .livesIn, to: "Haar", exchange: 1)],
                    endings: [.init(fact: 2, exchange: 1)]))
        #expect(throws: (any Error).self) {
            try MemoryReport(
                GeneratedContent(json: #"{"learned":[{"relation":"home","to":"Haar","exchange":1}],"ended":[]}"#))
        }
    }
}
