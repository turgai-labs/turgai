import Foundation
import Hail
import Testing
import TurgaiAgents
import TurgaiDomain

@testable import TurgaiApplication

struct AgentModelEndpointFactoryTests {
    /// Ollama's `think` is on or off: effort none turns it off for any model, and other levels
    /// still can't be expressed.
    @Test
    func ollamaTakesEffortNoneAsThinkingOff() async throws {
        let factory = AgentModelEndpointFactory(credentials: AgentCredentialStore(storage: .test))
        let model = try AgentModel(provider: .ollama, id: "qwen3.5:9b")
        let ollama = AgentProviderConfiguration.server(
            ModelServer(
                software: .ollama, address: .localOllama, key: nil, context: .chosen(try ContextWindow(tokens: 8192))))

        _ = try await factory.endpoint(
            model: model, configuration: ollama, temperature: 0, reasoning: ReasoningEffortSelection(effort: .none))
        await #expect(throws: ModelRouterError.self) {
            try await factory.endpoint(
                model: model, configuration: ollama, temperature: 0,
                reasoning: ReasoningEffortSelection(effort: .medium))
        }
    }

    /// An Ollama server's key is read from the credentials, as another provider's is: one that
    /// isn't there fails, as theirs does.
    @Test
    func ollamasKeyIsReadFromTheCredentials() async throws {
        let credentials = AgentCredentialStore(storage: .test)
        let factory = AgentModelEndpointFactory(credentials: credentials)
        let model = try AgentModel(provider: .ollama, id: "gpt-oss:120b")
        let key = AgentCredentialReference.new()
        let cloud = AgentProviderConfiguration.server(
            ModelServer(software: .ollama, address: .ollamaCloud, key: key, context: .providers(.unsaid)))

        await #expect(throws: AgentModelEndpointFactoryError.missingCredential(key)) {
            try await factory.endpoint(model: model, configuration: cloud, temperature: 0)
        }
        try await credentials.save("secret", for: key)
        _ = try await factory.endpoint(model: model, configuration: cloud, temperature: 0)
    }
}
