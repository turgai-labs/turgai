import Foundation
import Testing
import TurgaiMemory

@testable import TurgaiApplication

/// What the extractor is shown of a conversation.
struct MemoryExtractionTests {
    @Test("short answers retain the assistant question")
    func exchangeContext() {
        let question = MemoryObservation(
            sourceID: MemorySourceID(), text: "Weather please",
            response: "Which location?", observedAt: Date())
        let answer = MemoryObservation(sourceID: MemorySourceID(), text: "Haar, Germany", observedAt: Date())
        #expect(
            MemoryExtractionService.transcript([question, answer])
                == "user [1]: Weather please\nassistant [1]: Which location?\nuser [2]: Haar, Germany")
    }
}
