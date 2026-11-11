import Foundation
import Hail
import Testing
import TurgaiApplication
import TurgaiHail
import TurgaiPersistence

@Suite("Turgai agent profiles")
struct TurgaiAgentProfileTests {
    private let localOllama = AgentProviderConfiguration.server(
        ModelServer(software: .ollama, address: .localOllama, key: nil, contextWindow: .standard))

    private func cloud(_ provider: CloudAccount.Provider, tokens: Int = 16_384) throws -> AgentProviderConfiguration {
        .cloud(CloudAccount(provider: provider, key: .new(), contextWindow: try ContextWindow(tokens: tokens)))
    }

    @Test("creates the default profile, its model the configuration's provider's")
    func defaultProfile() async throws {
        let store = TurgaiAgentProfileStore(storage: .test)
        let profile = try await store.create(
            name: "Conversation", providerConfiguration: localOllama, modelID: AgentModelID(rawValue: "qwen3.5:9b"))

        #expect(profile.id == TurgaiAgentProfileStore.defaultProfileID)
        #expect(profile.name == "Conversation")
        #expect(profile.model.identifier == "ollama/qwen3.5:9b")
        #expect(profile.providerConfiguration == localOllama)
        #expect(profile.contextWindow == ContextWindow.standard.tokens)
        #expect(profile.persona == nil)
    }

    /// In Turgai's database itself, whose table checks each kind's settings.
    @Test("keeps each kind of provider as it's configured")
    func eachKindIsKept() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = try await TurgaiPersistence.open(in: directory)
        let store = TurgaiAgentProfileStore(storage: try await .live(in: persistence))
        let server = try ServerAddress("http://models.test:8080/v1")
        var configurations: [AgentProviderConfiguration] = [
            .local(.appleSystem),
            localOllama,
            .server(
                ModelServer(
                    software: .ollama, address: .ollamaCloud, key: .new(),
                    contextWindow: try ContextWindow(tokens: 32_768))),
            .server(
                ModelServer(
                    software: .openAICompatible(.chatCompletions), address: server, key: nil,
                    contextWindow: .standard)),
            .server(
                ModelServer(
                    software: .openAICompatible(.responses), address: server, key: .new(), contextWindow: .standard)),
            try cloud(.openAI, tokens: 128_000),
            try cloud(.anthropic, tokens: 200_000),
            try cloud(.gemini, tokens: 1_048_576),
        ]
        #if Llama
            configurations.append(
                .local(.llamaCPP(file: "/models/qwen.gguf", gpuLayers: -1, contextWindow: .standard)))
        #endif
        for (index, configuration) in configurations.enumerated() {
            let profile = try await store.create(
                name: "Bot \(index)", providerConfiguration: configuration, modelID: AgentModelID(rawValue: "model"))
            let kept = try #require(try await store.profile(id: profile.id))
            #expect(kept.providerConfiguration == configuration)
            #expect(kept.model == profile.model)
        }
        try await persistence.close()
    }

    @Test("does not invent a profile ID for an empty catalog")
    func emptyCatalogHasNoRoutableProfile() async throws {
        let store = TurgaiAgentProfileStore(storage: .test)
        await #expect(throws: TurgaiAgentProfileError.noEnabledProfile) {
            try await store.defaultProfileID()
        }
    }

    @Test("preserves an explicitly empty persona without restoring a default")
    func emptyPersonaIsConfiguration() async throws {
        let store = TurgaiAgentProfileStore(storage: .test)
        let profile = try await store.create(
            name: "Quiet", providerConfiguration: try cloud(.openAI), modelID: AgentModelID(rawValue: "gpt-4.1"),
            persona: "   ")

        #expect(profile.persona == "   ")
    }

    @Test("captures the profile's provider for memory extraction")
    func extractionProviderMapping() throws {
        let ollama = try TurgaiAgentProfile(
            id: "local", name: "Local", providerConfiguration: localOllama, modelID: AgentModelID(rawValue: "llama3.2"))
        let cloud = try TurgaiAgentProfile(
            id: "cloud", name: "Cloud", providerConfiguration: try cloud(.openAI),
            modelID: AgentModelID(rawValue: "gpt-4.1"))

        #expect(
            AgentModelSnapshot(profile: ollama).provider
                == .configured(ollama.providerConfiguration, ollamaKeepAlive: "10m"))
        #expect(
            AgentModelSnapshot(profile: cloud).provider
                == .configured(cloud.providerConfiguration, ollamaKeepAlive: nil))
        #expect(!AgentModelSnapshot(model: cloud.model, provider: .disabled).isEnabled)
    }

    @Test("takes the on-device model's context window from the model")
    func appleSystemWindowIsTheModels() throws {
        let profile = try TurgaiAgentProfile(
            id: "local", name: "Local", providerConfiguration: .local(.appleSystem),
            modelID: AgentModelID(rawValue: "default"))
        #expect(profile.model.provider == .system)
        #expect(profile.contextWindow == LocalModel.appleSystemContextWindow)
    }

    @Test("moves a profile to another provider, its model with it")
    func movingToAnotherProvider() async throws {
        let store = TurgaiAgentProfileStore(storage: .test)
        let local = try await store.create(
            name: "Local", providerConfiguration: localOllama, modelID: AgentModelID(rawValue: "llama3.2"))
        var moved = local
        let cloudConfiguration = try cloud(.openAI)
        try moved.use(cloudConfiguration, model: AgentModelID(rawValue: "gpt-4.1"))

        try await store.update(moved)

        let updated = try #require(try await store.profile(id: local.id))
        #expect(updated.model.identifier == "openai/gpt-4.1")
        #expect(updated.providerConfiguration == cloudConfiguration)
    }

    @Test("the first profile is the default, and the default stays while it is")
    func theDefaultStays() async throws {
        let store = TurgaiAgentProfileStore(storage: .test)
        let first = try await store.create(
            name: "First", providerConfiguration: try cloud(.openAI), modelID: AgentModelID(rawValue: "gpt-4.1"))
        let second = try await store.create(
            name: "Second", providerConfiguration: try cloud(.openAI), modelID: AgentModelID(rawValue: "gpt-4.1"))

        #expect(try await store.defaultProfileID() == first.id)
        await #expect(throws: TurgaiAgentProfileError.cannotDeleteDefaultProfile) {
            try await store.delete(id: first.id)
        }
        try await store.setDefaultProfile(id: second.id)
        try await store.delete(id: first.id)
        #expect(try await store.profiles().map(\.id) == [second.id])
        await #expect(throws: TurgaiAgentProfileError.unknownProfile(first.id)) {
            try await store.delete(id: first.id)
        }
    }
}

@Suite("A bot's context window")
struct ContextWindowChoiceTests {
    private let ollama = ModelLocation.server(.ollama, .localOllama)
    private let openAI = ModelLocation.cloud(.openAI)

    @Test("a typed window is kept, when the model takes that many")
    func typedIsKept() throws {
        let typed = try ContextWindow(tokens: 8_192)
        #expect(try ContextWindow.chosen(typed: typed, modelTakes: 131_072, at: ollama) == typed)
        #expect(try ContextWindow.chosen(typed: typed, modelTakes: nil, at: openAI) == typed)
        #expect(throws: ContextWindowChoiceError.aboveModel(typed: 8_192, model: 4_096)) {
            try ContextWindow.chosen(typed: typed, modelTakes: 4_096, at: openAI)
        }
    }

    @Test("none typed is the model's own, on an Ollama server no more than the standard")
    func noneTypedIsTheModels() throws {
        #expect(try ContextWindow.chosen(typed: nil, modelTakes: 128_000, at: openAI).tokens == 128_000)
        #expect(try ContextWindow.chosen(typed: nil, modelTakes: 1_048_576, at: ollama) == .standard)
        #expect(try ContextWindow.chosen(typed: nil, modelTakes: 8_192, at: ollama).tokens == 8_192)
        #expect(throws: ContextWindowChoiceError.unknown) {
            try ContextWindow.chosen(typed: nil, modelTakes: nil, at: openAI)
        }
    }
}
