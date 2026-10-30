import Foundation
import Hail
import Testing

@testable import TurgaiApplication

struct AgentModelEndpointFactoryTests {
    /// Ollama's `think` is on or off: effort none turns it off for any model, and other levels
    /// still can't be expressed.
    @Test
    func ollamaTakesEffortNoneAsThinkingOff() async throws {
        let factory = AgentModelEndpointFactory(credentials: AgentCredentialStore(storage: .test))
        let model = try AgentModel(provider: .ollama, id: "qwen3.5:9b")
        let ollama = AgentProviderConfiguration.ollama(
            baseURL: URL(string: "http://127.0.0.1:11434")!, contextWindow: 8192)

        _ = try await factory.endpoint(
            model: model, configuration: ollama, temperature: 0, reasoning: ReasoningEffortSelection(effort: .none))
        await #expect(throws: ModelRouterError.self) {
            try await factory.endpoint(
                model: model, configuration: ollama, temperature: 0,
                reasoning: ReasoningEffortSelection(effort: .medium))
        }
    }
}
