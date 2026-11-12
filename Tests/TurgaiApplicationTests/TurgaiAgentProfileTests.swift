import AnyLanguageModel
import Foundation
import Hail
import Testing
import TurgaiHail
import TurgaiPersistence

@testable import TurgaiApplication

@Suite("Turgai agent profiles")
struct TurgaiAgentProfileTests {
    private let localOllama = AgentProviderConfiguration.server(
        ModelServer(software: .ollama, address: .localOllama, key: nil, context: .chosen(.standard)))

    private func cloud(_ provider: CloudAccount.Provider, tokens: Int? = nil) throws -> AgentProviderConfiguration {
        .cloud(CloudAccount(provider: provider, key: .new(), window: ProviderWindow(modelTakes: tokens)))
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
                    context: .providers(.said(try ContextWindow(tokens: 1_048_576))))),
            .server(
                ModelServer(
                    software: .openAICompatible(.chatCompletions), address: server, key: nil,
                    context: .providers(.unsaid))),
            .server(
                ModelServer(
                    software: .openAICompatible(.responses), address: server, key: .new(),
                    context: .providers(.said(.standard)))),
            try cloud(.openAI),
            try cloud(.anthropic, tokens: 1_000_000),
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
struct ModelContextTests {
    private let ollama = ModelLocation.server(.ollama, .localOllama)
    private let model = AgentModelID(rawValue: "qwen3:8b")

    private func context(
        _ location: ModelLocation, _ model: AgentModelID, typed: Int? = nil, modelTakes: Int?
    ) throws -> AgentProviderConfiguration {
        try location.configuration(
            key: .new(), model: model, typed: try typed.map { try ContextWindow(tokens: $0) }, modelTakes: modelTakes)
    }

    @Test("on your own Ollama server it's yours: typed, when the model takes that many")
    func typedOnYourOwnServer() throws {
        #expect(try context(ollama, model, typed: 8_192, modelTakes: 131_072).contextWindow == 8_192)
        #expect(try context(ollama, model, typed: 8_192, modelTakes: nil).contextWindow == 8_192)
        #expect(throws: ModelConfigurationError.windowAboveModel(typed: 8_192, model: 4_096)) {
            try context(ollama, model, typed: 8_192, modelTakes: 4_096)
        }
    }

    @Test("on your own Ollama server, none typed is the model's own, no more than the standard")
    func noneTypedOnYourOwnServer() throws {
        #expect(try context(ollama, model, modelTakes: 1_048_576).contextWindow == ContextWindow.standard.tokens)
        #expect(try context(ollama, model, modelTakes: 8_192).contextWindow == 8_192)
        #expect(throws: ModelConfigurationError.windowUnknown) { try context(ollama, model, modelTakes: nil) }
    }

    /// Ollama's cloud runs its models with their own window, asked directly or through a server
    /// of your own, and a cloud runs its models with its own window, whatever's typed.
    @Test("a provider's window is its own: said when it says it, else unsaid")
    func providersWindowIsItsOwn() throws {
        let flash = AgentModelID(rawValue: "deepseek-v4.1-flash")
        let viaCloud = try context(.server(.ollama, .ollamaCloud), flash, typed: 4_096, modelTakes: 1_048_576)
        #expect(viaCloud.contextWindow == 1_048_576)
        guard case .server(let server) = viaCloud else {
            Issue.record("Ollama's cloud wasn't configured as a server")
            return
        }
        #expect(server.context == .providers(.said(try ContextWindow(tokens: 1_048_576))))
        let passedOn = try context(ollama, AgentModelID(rawValue: "gpt-oss:120b-cloud"), modelTakes: 131_072)
        #expect(passedOn.contextWindow == 131_072)
        let openAI = try context(.cloud(.openAI), AgentModelID(rawValue: "gpt-5"), typed: 8_192, modelTakes: nil)
        #expect(openAI.contextWindow == nil)
        let compatible = try context(
            .server(.openAICompatible(.chatCompletions), try ServerAddress("http://models.test")), model,
            modelTakes: nil)
        #expect(compatible.contextWindow == nil)
    }

    @Test("a cloud without a key isn't configured")
    func aCloudNeedsAKey() {
        #expect(throws: ModelConfigurationError.keyNeeded) {
            try ModelLocation.cloud(.gemini).configuration(
                key: nil, model: AgentModelID(rawValue: "gemini-pro"), typed: nil, modelTakes: 1_048_576)
        }
    }
}

@Suite("A provider's models")
struct ModelOrderTests {
    @Test("are in the order a person reads them: numbers by value, letters regardless of case")
    func naturalOrder() {
        let names = ["gpt-oss:120b", "Qwen3:8b", "gpt-oss:20b", "qwen3:32b", "glm-5.3", "glm-5.2"]
        #expect(
            names.sorted(by: ModelLocation.naturally)
                == ["glm-5.2", "glm-5.3", "gpt-oss:20b", "gpt-oss:120b", "Qwen3:8b", "qwen3:32b"])
    }
}

@Suite("Where a bot's model runs")
struct ModelLocationTests {
    @Test("Ollama's cloud needs a key, though it shows its models to anyone")
    func ollamasCloudNeedsAKey() async throws {
        let cloud = ModelLocation.server(.ollama, try ServerAddress("https://ollama.com/"))
        let availability = try await cloud.checkAvailability(of: AgentModelID(rawValue: "gpt-oss:120b"), key: nil)
        guard case .unavailable(let reason) = availability else {
            Issue.record("Ollama's cloud without a key was available")
            return
        }
        #expect(reason.kind == .keyNeeded)
    }
}
