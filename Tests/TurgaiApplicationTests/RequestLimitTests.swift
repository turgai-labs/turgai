import Foundation
import Hail
import Testing

@testable import TurgaiApplication

@Suite("Request limits")
struct RequestLimitTests {
    @Test func eachProviderAccountIsItsOwn() throws {
        let local = AgentProviderConfiguration.ollama(
            baseURL: URL(string: "http://127.0.0.1:11434")!, contextWindow: 16_384)
        #expect(
            local.account(for: try AgentModel(provider: .ollama, id: "deepseek-v4.1-flash:cloud"))
                == ModelAccount(rawValue: "ollama-cloud"))
        #expect(
            local.account(for: try AgentModel(provider: .ollama, id: "qwen3.5:9b"))
                == ModelAccount(rawValue: "ollama@127.0.0.1"))
        let compatible = AgentProviderConfiguration.openAICompatible(
            baseURL: URL(string: "https://api.deepseek.com/v1")!, credential: .new(), api: .chatCompletions,
            contextWindow: 65_536)
        #expect(
            compatible.account(for: try AgentModel(provider: .openAICompatible, id: "deepseek-chat"))
                == ModelAccount(rawValue: "api.deepseek.com"))
        #expect(
            AgentProviderConfiguration.appleSystem.account(for: try AgentModel(provider: .system, id: "default")) == nil
        )
    }

    /// The default is kept whatever is set next, and a lifted one stays lifted.
    @Test func theDefaultIsKeptAndALiftedLimitStaysLifted() async throws {
        let storage = RequestLimitStorage.test
        let first = try await RequestLimitStore(storage: storage)
        try await first.setLimit(2, for: ModelAccount(rawValue: "anthropic"))
        let second = try await RequestLimitStore(storage: storage)
        #expect(try await second.limit(for: ModelAccount(rawValue: "ollama-cloud")) == 1)
        try await second.setLimit(nil, for: ModelAccount(rawValue: "ollama-cloud"))
        let third = try await RequestLimitStore(storage: storage)
        #expect(try await third.limit(for: ModelAccount(rawValue: "ollama-cloud")) == nil)
        #expect(try await third.limit(for: ModelAccount(rawValue: "anthropic")) == 2)
    }

    @Test func aLimitIsKeptAcrossRestarts() async throws {
        let storage = RequestLimitStorage.test
        let first = try await RequestLimitStore(storage: storage)
        // A new installation starts with Ollama's cloud at one request at a time.
        #expect(try await first.limit(for: ModelAccount(rawValue: "ollama-cloud")) == 1)
        try await first.setLimit(3, for: ModelAccount(rawValue: "ollama-cloud"))
        try await first.setLimit(4, for: ModelAccount(rawValue: "anthropic"))
        let second = try await RequestLimitStore(storage: storage)
        #expect(try await second.limit(for: ModelAccount(rawValue: "ollama-cloud")) == 3)
        #expect(try await second.limit(for: ModelAccount(rawValue: "anthropic")) == 4)
        #expect(
            await second.transports.limits == [
                ModelAccount(rawValue: "ollama-cloud"): 3, ModelAccount(rawValue: "anthropic"): 4,
            ])
    }
}
