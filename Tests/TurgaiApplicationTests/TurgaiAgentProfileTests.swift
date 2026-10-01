import Foundation
import Hail
import Testing
import TurgaiApplication
import TurgaiHail
import TurgaiPersistence

@Suite("Turgai agent profiles")
struct TurgaiAgentProfileTests {
    @Test("creates the default profile with a concrete Ollama endpoint")
    func defaultProfile() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try TurgaiAgentProfileStore(files: FileClient(directory: directory))
        let profile = try await store.create(
            name: "Conversation",
            model: try AgentModel("ollama/qwen3.5:9b"),
            providerConfiguration: .ollama(baseURL: OllamaConfiguration.defaultBaseURL, contextWindow: 16_384)
        )

        #expect(profile.id == TurgaiAgentProfileStore.defaultProfileID)
        #expect(profile.name == "Conversation")
        #expect(profile.model.identifier == "ollama/qwen3.5:9b")
        #expect(
            profile.providerConfiguration == .ollama(baseURL: OllamaConfiguration.defaultBaseURL, contextWindow: 16_384)
        )
        #expect(profile.contextWindow == 16_384)
        #expect(profile.persona == nil)
    }

    @Test("does not require an Ollama endpoint for another provider")
    func nonOllamaProfile() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try TurgaiAgentProfileStore(files: FileClient(directory: directory))
        let cloud = AgentProviderConfiguration.openAI(credential: .new(), contextWindow: 128_000)
        let profile = try await store.create(
            name: "Cloud",
            model: try AgentModel("openai/gpt-4.1"),
            providerConfiguration: cloud
        )

        #expect(profile.model.provider == .openAI)
        #expect(profile.providerConfiguration == cloud)
        #expect(profile.contextWindow == 128_000)
    }

    @Test("does not invent a profile ID for an empty catalog")
    func emptyCatalogHasNoRoutableProfile() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try TurgaiAgentProfileStore(files: FileClient(directory: directory))
        await #expect(throws: TurgaiAgentProfileError.noEnabledProfile) {
            try await store.defaultProfileID()
        }
    }

    @Test("preserves an explicitly empty persona without restoring a default")
    func emptyPersonaIsConfiguration() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try TurgaiAgentProfileStore(files: FileClient(directory: directory))
        let profile = try await store.create(
            name: "Quiet",
            model: try AgentModel("openai/gpt-4.1"),
            providerConfiguration: .openAI(credential: .new(), contextWindow: 16_384),
            persona: "   "
        )

        #expect(profile.persona == "   ")
    }

    @Test("captures the profile's provider for memory extraction")
    func extractionProviderMapping() throws {
        let ollama = TurgaiAgentProfile(
            id: "local",
            name: "Local",
            model: try AgentModel("ollama/llama3.2"),
            providerConfiguration: .ollama(baseURL: OllamaConfiguration.defaultBaseURL, contextWindow: 16_384)
        )
        let cloud = TurgaiAgentProfile(
            id: "cloud",
            name: "Cloud",
            model: try AgentModel("openai/gpt-4.1"),
            providerConfiguration: .openAI(credential: .new(), contextWindow: 16_384)
        )

        #expect(
            MemoryExtractionConfiguration(profile: ollama).provider
                == .configured(ollama.providerConfiguration, ollamaKeepAlive: "10m"))
        #expect(
            MemoryExtractionConfiguration(profile: cloud).provider
                == .configured(cloud.providerConfiguration, ollamaKeepAlive: nil))
        #expect(!MemoryExtractionConfiguration(model: cloud.model, provider: .disabled).isEnabled)
    }

    @Test("takes the on-device model's context window from the model")
    func appleSystemWindowIsTheModels() throws {
        let profile = TurgaiAgentProfile(
            id: "local",
            name: "Local",
            model: try AgentModel("system/default"),
            providerConfiguration: .appleSystem
        )
        #expect(profile.contextWindow == AgentProviderConfiguration.appleSystemContextWindow)
    }

    @Test("applies endpoint removal on the next profile snapshot")
    func endpointRemovalIsApplied() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try TurgaiAgentProfileStore(files: FileClient(directory: directory))
        let local = try await store.create(
            name: "Local",
            model: try AgentModel("ollama/llama3.2"),
            providerConfiguration: .ollama(baseURL: OllamaConfiguration.defaultBaseURL, contextWindow: 16_384)
        )
        var cloud = local
        cloud.model = try AgentModel("openai/gpt-4.1")
        let cloudConfiguration = AgentProviderConfiguration.openAI(credential: .new(), contextWindow: 16_384)
        cloud.providerConfiguration = cloudConfiguration

        try await store.update(cloud)

        let updated = try #require(await store.profile(id: local.id))
        #expect(updated.model.provider == .openAI)
        #expect(updated.providerConfiguration == cloudConfiguration)
    }

    @Test("decodes the current profile representation")
    func profileRoundTripShape() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let state = Data(
            #"{"defaultProfileID":"conversation","profiles":[{"id":"conversation","name":"Conversation","model":"ollama/llama3.2","providerConfiguration":{"ollama":{"baseURL":"http://127.0.0.1:11434","contextWindow":8192}},"instructions":"","availability":"enabled"}]}"#
                .utf8
        )
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("agents", isDirectory: true), withIntermediateDirectories: true)
        try state.write(to: directory.appendingPathComponent("agents/profiles.json"))

        let store = try TurgaiAgentProfileStore(files: FileClient(directory: directory))

        #expect((await store.defaultProfile())?.persona == nil)
        #expect((await store.defaultProfile())?.contextWindow == 8192)
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("turgai-agent-profile-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
