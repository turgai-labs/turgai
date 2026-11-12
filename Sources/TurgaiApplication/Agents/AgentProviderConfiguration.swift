import AnyLanguageModel
import Hail

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// A provider a bot's model comes from, without its settings: what a form offers and keeps.
public enum AgentProvider: Hashable, Sendable, CaseIterable {
    /// Apple's on-device model.
    case appleSystem
    #if Llama
        /// A GGUF file run by llama.cpp.
        case llamaCPP
    #endif
    case ollama
    /// A server that speaks OpenAI's API.
    case openAICompatible
    case openAI
    case anthropic
    case gemini

    /// Where a provider's models run: on this machine; on a server at an address, on this machine,
    /// the network or hosted; or in a provider's cloud.
    public enum Kind: Sendable, CaseIterable {
        case local
        case server
        case cloud
    }

    public var kind: Kind {
        switch self {
        case .appleSystem: .local
        #if Llama
            case .llamaCPP: .local
        #endif
        case .ollama, .openAICompatible: .server
        case .openAI, .anthropic, .gemini: .cloud
        }
    }

    /// Its name, as it's kept and sent, and as Hail names it in a model's identifier.
    public var name: String { modelProvider.rawValue }

    /// The provider `name` names: none when it names none Turgai offers.
    public init?(name: String) {
        guard let provider = Self.allCases.first(where: { $0.name == name }) else { return nil }
        self = provider
    }

    /// Hail's name for it.
    public var modelProvider: AgentModelProvider {
        switch self {
        case .appleSystem: .system
        #if Llama
            case .llamaCPP: .llamaCPP
        #endif
        case .ollama: .ollama
        case .openAICompatible: .openAICompatible
        case .openAI: .openAI
        case .anthropic: .anthropic
        case .gemini: .gemini
        }
    }
}

/// Where a bot's model runs, and what reaching it takes: on this machine; on a server at an
/// address; or in a provider's cloud, with an account's key.
public enum AgentProviderConfiguration: Codable, Sendable, Equatable {
    case local(LocalModel)
    case server(ModelServer)
    case cloud(CloudAccount)

    public var provider: AgentProvider {
        switch self {
        case .local(.appleSystem): .appleSystem
        #if Llama
            case .local(.llamaCPP): .llamaCPP
        #endif
        case .server(let server):
            switch server.software {
            case .ollama: .ollama
            case .openAICompatible: .openAICompatible
            }
        case .cloud(let account):
            switch account.provider {
            case .openAI: .openAI
            case .anthropic: .anthropic
            case .gemini: .gemini
            }
        }
    }

    /// The key it's reached with, when it has one.
    public var credentialReference: AgentCredentialReference? {
        switch self {
        case .local: nil
        case .server(let server): server.key
        case .cloud(let account): account.key
        }
    }

    /// How many tokens a prompt may use with it, when that's known: a provider that doesn't say
    /// its window has none, and the conversation is shortened when it refuses a request.
    public var contextWindow: Int? {
        switch self {
        case .local(.appleSystem): LocalModel.appleSystemContextWindow
        #if Llama
            case .local(.llamaCPP(_, _, let window)): window.tokens
        #endif
        case .server(let server): server.context.window?.tokens
        case .cloud(let account): account.window.window?.tokens
        }
    }
}

/// A model run on this machine.
public enum LocalModel: Codable, Sendable, Equatable {
    /// Apple's on-device model. Its context window isn't a setting: the model reports it, and it
    /// differs between OS releases.
    case appleSystem
    #if Llama
        /// A GGUF file run by llama.cpp.
        case llamaCPP(file: String, gpuLayers: Int32, contextWindow: ContextWindow)
    #endif

    /// The on-device model's own context window.
    public static var appleSystemContextWindow: Int {
        #if canImport(FoundationModels)
            SystemLanguageModel.default.contextSize
        #else
            0
        #endif
    }
}

/// A server that speaks a model API at an address: on this machine, on the network, or hosted.
public struct ModelServer: Codable, Sendable, Equatable {
    /// Which API it speaks.
    public enum Software: Codable, Sendable, Equatable {
        case ollama
        case openAICompatible(OpenAICompatibleAPI)
    }

    public var software: Software
    public var address: ServerAddress
    /// The key it asks for, when it asks for one: a local server asks for none.
    public var key: AgentCredentialReference?
    public var context: ModelContext

    public init(software: Software, address: ServerAddress, key: AgentCredentialReference?, context: ModelContext) {
        self.software = software
        self.address = address
        self.key = key
        self.context = context
    }
}

/// An account with a provider's cloud, reached at the provider's own address with its key.
public struct CloudAccount: Codable, Sendable, Equatable {
    public enum Provider: String, Codable, Sendable, CaseIterable {
        case openAI
        case anthropic
        case gemini
    }

    public var provider: Provider
    public var key: AgentCredentialReference
    /// A cloud runs a model with its own window.
    public var window: ProviderWindow

    public init(provider: Provider, key: AgentCredentialReference, window: ProviderWindow) {
        self.provider = provider
        self.key = key
        self.window = window
    }
}

/// How much context a server's model gets: as much as you give it, on a server of your own, which
/// keeps memory for it; or the window the provider runs it with.
public enum ModelContext: Codable, Sendable, Equatable {
    case chosen(ContextWindow)
    case providers(ProviderWindow)

    public var window: ContextWindow? {
        switch self {
        case .chosen(let window): window
        case .providers(let provider): provider.window
        }
    }
}

/// The window a provider runs a model with: its own, which the provider says, or doesn't.
public enum ProviderWindow: Codable, Sendable, Equatable {
    case said(ContextWindow)
    /// The provider doesn't say it: the conversation is shortened when the provider refuses a
    /// request as too long.
    case unsaid

    /// The window of a model that takes `modelTakes` tokens, as the provider says, when it does.
    public init(modelTakes: Int?) {
        if let modelTakes, let window = try? ContextWindow(tokens: modelTakes) {
            self = .said(window)
        } else {
            self = .unsaid
        }
    }

    public var window: ContextWindow? {
        if case .said(let window) = self { window } else { nil }
    }
}

/// Which of OpenAI's APIs a server speaks.
public enum OpenAICompatibleAPI: String, Codable, Sendable, Equatable {
    case chatCompletions
    case responses
}

/// A server's address: an http(s) URL with a host.
public struct ServerAddress: Codable, Sendable, Hashable, CustomStringConvertible {
    public let url: URL

    /// `url`, when it's a server's address.
    public init(_ url: URL) throws(ServerAddressError) {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", url.host() != nil
        else { throw .notHTTP(url.absoluteString) }
        self.url = url
    }

    /// The address `written` says.
    public init(_ written: String) throws(ServerAddressError) {
        guard let url = URL(string: written.trimmed()) else { throw .notHTTP(written) }
        try self.init(url)
    }

    public init(from decoder: any Decoder) throws {
        try self.init(try decoder.singleValueContainer().decode(URL.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(url)
    }

    public var description: String { url.absoluteString }

    /// Whether it's the same server as `other`'s, a trailing slash aside.
    public func isSameServer(as other: ServerAddress) -> Bool {
        func written(_ url: URL) -> String {
            let text = url.absoluteString
            return text.hasSuffix("/") ? String(text.dropLast()) : text
        }
        return written(url) == written(other.url)
    }

    /// Ollama on this machine.
    public static let localOllama = Self(known: URL(string: "http://127.0.0.1:11434")!)

    /// Ollama's cloud.
    public static let ollamaCloud = Self(known: URL(string: "https://ollama.com")!)

    private init(known url: URL) {
        self.url = url
    }
}

public enum ServerAddressError: Error, Equatable, Sendable {
    /// What was given isn't an http(s) URL with a host.
    case notHTTP(String)
}

/// How many tokens a prompt may use: at least one.
public struct ContextWindow: Codable, Sendable, Hashable, Comparable {
    public let tokens: Int

    public init(tokens: Int) throws(ContextWindowError) {
        guard tokens > 0 else { throw .notPositive(tokens) }
        self.tokens = tokens
    }

    public init(from decoder: any Decoder) throws {
        try self.init(tokens: try decoder.singleValueContainer().decode(Int.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(tokens)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.tokens < rhs.tokens }

    /// What a server's model is given when nothing else says: as much as a local model's memory
    /// comfortably takes.
    public static let standard = Self(known: 16_384)

    private init(known tokens: Int) {
        self.tokens = tokens
    }
}

public enum ContextWindowError: Error, Equatable, Sendable {
    case notPositive(Int)
}
