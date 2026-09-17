import Foundation
import Hail
import Testing
import TurgaiApplication
import TurgaiHail
import TurgaiWeb

@Suite("Turgai model catalog")
struct TurgaiModelCatalogTests {
    @Test("keeps model choices scoped to their provider")
    func providerChoices() async throws {
        let configuredProfile = TurgaiAgentProfile(
            id: "conversation",
            name: "Conversation",
            model: try AgentModel("openai/gpt-4.1")
        )
        let catalog = await TurgaiModelCatalogLoader.load(
            profiles: [configuredProfile],
            discovery: Self.emptyDiscovery
        )

        #expect(catalog.providers.contains { $0.provider == .ollama })
        #expect(catalog.providers.contains { $0.provider == .openAI })
        #expect(catalog.choices(for: .openAI).map(\.identifier) == ["openai/gpt-4.1"])
        #expect(catalog.choices(for: .ollama).isEmpty)
        #expect(catalog.notice(for: .openAI)?.contains("account") == true)

        #if canImport(FoundationModels)
            #expect(catalog.choices(for: .system).map(\.identifier) == ["system/default"])
        #endif
    }

    @Test("preserves configured providers that have no discovery adapter")
    func configuredManualProvider() async throws {
        let configuredProfile = TurgaiAgentProfile(
            id: "conversation",
            name: "Conversation",
            model: try AgentModel("custom-provider/quiet-model")
        )
        let catalog = await TurgaiModelCatalogLoader.load(
            profiles: [configuredProfile],
            discovery: Self.emptyDiscovery
        )

        let provider = AgentModelProvider(rawValue: "custom-provider")
        #expect(
            catalog.provider(for: ModelProviderID(rawValue: provider.rawValue))?.provider.rawValue == provider.rawValue)
        let providerID = ModelProviderID(rawValue: provider.rawValue)
        #expect(catalog.choices(for: providerID).map(\.identifier) == ["custom-provider/quiet-model"])
        #expect(catalog.notice(for: providerID) == "Enter a model ID for this provider.")
    }

    @Test("discovers models from every configured Ollama server")
    func ollamaDiscoveryUsesProfileEndpoints() async throws {
        let firstProfile = TurgaiAgentProfile(
            id: "first",
            name: "First",
            model: try AgentModel("ollama/llama3.2"),
            ollamaBaseURL: URL(string: "http://first.test:11434")!
        )
        let secondProfile = TurgaiAgentProfile(
            id: "second",
            name: "Second",
            model: try AgentModel("ollama/mistral"),
            ollamaBaseURL: URL(string: "http://second.test:11434")!
        )
        let discovery = TurgaiModelCatalogLoader.Discovery(
            ollama: { url in
                url.host == "first.test" ? ["llama3.2"] : ["mistral"]
            }
        )
        let catalog = await TurgaiModelCatalogLoader.load(
            profiles: [firstProfile, secondProfile],
            discovery: discovery
        )

        #expect(
            catalog.choices(for: .ollama).map(\.identifier) == [
                "ollama/llama3.2",
                "ollama/mistral",
            ]
        )
    }

    private static let emptyDiscovery = TurgaiModelCatalogLoader.Discovery(
        ollama: { _ in [] }
    )
}
