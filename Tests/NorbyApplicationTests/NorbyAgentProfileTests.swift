import Foundation
import Hail
import NorbyApplication
import NorbyDomain
import NorbyHail
import Testing

@Suite("Norby agent profiles")
struct NorbyAgentProfileTests {
    @Test("creates the default profile with a concrete Ollama endpoint")
    func defaultProfile() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try NorbyAgentProfileStore(directory: directory)
        let profile = try await store.create(
            name: "Conversation",
            model: try AgentModel("ollama/qwen3.5:9b"),
            ollamaBaseURL: OllamaConfiguration.defaultBaseURL
        )

        #expect(profile.id == NorbyAgentProfileStore.defaultProfileID)
        #expect(profile.name == "Conversation")
        #expect(profile.model.identifier == "ollama/qwen3.5:9b")
        #expect(profile.ollamaBaseURL == .some(OllamaConfiguration.defaultBaseURL))
        #expect(profile.persona == nil)
    }

    @Test("does not require an Ollama endpoint for another provider")
    func nonOllamaProfile() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try NorbyAgentProfileStore(directory: directory)
        let profile = try await store.create(
            name: "Cloud",
            model: try AgentModel("openai/gpt-4.1")
        )

        #expect(profile.model.provider == .openAI)
        #expect(profile.ollamaBaseURL == nil)
    }

    @Test("routes Telegram chats to distinct profiles")
    func telegramRouting() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try NorbyAgentProfileStore(directory: directory)
        let researcher = try await store.create(
            name: "Researcher",
            model: try AgentModel("ollama/llama3.2"),
            ollamaBaseURL: OllamaConfiguration.defaultBaseURL,
            persona: "Be skeptical and cite evidence.",
            telegramChatIDs: [-100123]
        )

        let routedConversation = ConversationID(
            channel: ChannelID("telegram"),
            externalAddress: ExternalConversationAddress("-100123")
        )
        let defaultConversation = ConversationID(
            channel: ChannelID("telegram"),
            externalAddress: ExternalConversationAddress("456")
        )

        #expect(await store.profileID(for: routedConversation) == researcher.id)
        #expect(await store.profileID(for: defaultConversation) == researcher.id)
        #expect((await store.profile(id: researcher.id))?.persona == "Be skeptical and cite evidence.")
    }

    @Test("rejects a Telegram chat assigned to another profile")
    func duplicateTelegramChat() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try NorbyAgentProfileStore(directory: directory)
        _ = try await store.create(
            name: "Researcher",
            model: try AgentModel("ollama/llama3.2"),
            ollamaBaseURL: OllamaConfiguration.defaultBaseURL,
            telegramChatIDs: [123]
        )

        do {
            _ = try await store.create(
                name: "Writer",
                model: try AgentModel("ollama/llama3.2"),
                ollamaBaseURL: OllamaConfiguration.defaultBaseURL,
                telegramChatIDs: [123]
            )
            Issue.record("Expected duplicate Telegram chat ID to be rejected")
        } catch let error as NorbyAgentProfileError {
            #expect(error == .duplicateTelegramChatID(123))
        }
    }

    @Test("decodes a profile written before persona was added")
    func profileMigration() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let state = Data(
            #"{"defaultProfileID":"conversation","profiles":[{"id":"conversation","name":"Conversation","model":"ollama/llama3.2","ollamaBaseURL":"http://127.0.0.1:11434","contextWindow":8192,"instructions":"","enabled":true,"telegramChatIDs":[]}]}"#
                .utf8
        )
        try state.write(to: directory.appendingPathComponent("profiles.json"))

        let store = try NorbyAgentProfileStore(directory: directory)

        #expect((await store.defaultProfile())?.persona == nil)
        #expect((await store.defaultProfile())?.contextWindow == 8192)
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("norby-agent-profile-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
