import Foundation
import Hail
import Testing
import TurgaiPersistence

@testable import TurgaiApplication

@Suite("Request limits")
struct RequestLimitTests {
    @Test func eachProviderAccountIsItsOwn() throws {
        let local = AgentProviderConfiguration.ollama(baseURL: URL(string: "http://127.0.0.1:11434")!, contextWindow: 16_384)
        #expect(local.account(for: try AgentModel(provider: .ollama, id: "deepseek-v4.1-flash:cloud")) == ModelAccount(rawValue: "ollama-cloud"))
        #expect(local.account(for: try AgentModel(provider: .ollama, id: "qwen3.5:9b")) == ModelAccount(rawValue: "ollama@127.0.0.1"))
        let compatible = AgentProviderConfiguration.openAICompatible(
            baseURL: URL(string: "https://api.deepseek.com/v1")!, credential: .new(), api: .chatCompletions, contextWindow: 65_536)
        #expect(compatible.account(for: try AgentModel(provider: .openAICompatible, id: "deepseek-chat")) == ModelAccount(rawValue: "api.deepseek.com"))
        #expect(AgentProviderConfiguration.appleSystem.account(for: try AgentModel(provider: .system, id: "default")) == nil)
    }

    @Test func aLimitIsKeptAcrossRestarts() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try RequestLimitStore(files: try FileClient(directory: directory))
        // A new installation starts with Ollama's cloud at one request at a time.
        #expect(await first.limit(for: ModelAccount(rawValue: "ollama-cloud")) == 1)
        try await first.setLimit(3, for: ModelAccount(rawValue: "ollama-cloud"))
        try await first.setLimit(4, for: ModelAccount(rawValue: "anthropic"))
        let second = try RequestLimitStore(files: try FileClient(directory: directory))
        #expect(await second.limit(for: ModelAccount(rawValue: "ollama-cloud")) == 3)
        #expect(await second.limit(for: ModelAccount(rawValue: "anthropic")) == 4)
        #expect(await second.transports.limits == [ModelAccount(rawValue: "ollama-cloud"): 3, ModelAccount(rawValue: "anthropic"): 4])
    }
}
