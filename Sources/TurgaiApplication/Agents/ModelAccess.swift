import AnyLanguageModel
import Hail

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// Where a bot's model runs and how it's reached, without its key or window: what listing its
/// models and checking one ask.
public enum ModelLocation: Sendable, Equatable {
    case appleSystem
    #if Llama
        case llamaCPP(file: String, gpuLayers: Int32)
    #endif
    case server(ModelServer.Software, ServerAddress)
    case cloud(CloudAccount.Provider)

    public var provider: AgentProvider {
        switch self {
        case .appleSystem: .appleSystem
        #if Llama
            case .llamaCPP: .llamaCPP
        #endif
        case .server(.ollama, _): .ollama
        case .server(.openAICompatible, _): .openAICompatible
        case .cloud(.openAI): .openAI
        case .cloud(.anthropic): .anthropic
        case .cloud(.gemini): .gemini
        }
    }

    /// Whether a key for `other` is one for it too: the same cloud, or the same server.
    public func sharesKey(with other: ModelLocation) -> Bool {
        switch (self, other) {
        case (.cloud(let one), .cloud(let another)): one == another
        case (.server(_, let one), .server(_, let another)): one.isSameServer(as: another)
        default: false
        }
    }

    /// A bot's model here, reached with the key `key` refers to and given `window` tokens: Apple's
    /// on-device model's window is its own.
    ///
    /// - Throws: ``ModelUnavailability`` with ``ModelUnavailability/Kind/keyNeeded``, for a cloud
    ///   without a key.
    public func configuration(key: AgentCredentialReference?, window: ContextWindow) throws(ModelUnavailability)
        -> AgentProviderConfiguration
    {
        switch self {
        case .appleSystem:
            return .local(.appleSystem)
        #if Llama
            case .llamaCPP(let file, let layers):
                return .local(.llamaCPP(file: file, gpuLayers: layers, contextWindow: window))
        #endif
        case .server(let software, let address):
            return .server(ModelServer(software: software, address: address, key: key, contextWindow: window))
        case .cloud(let provider):
            guard let key else { throw ModelUnavailability(kind: .keyNeeded) }
            return .cloud(CloudAccount(provider: provider, key: key, contextWindow: window))
        }
    }

    /// The models it offers, by their IDs, as AnyLanguageModel lists them, asked with `key`:
    /// Apple's on-device model is its one model; a GGUF file is whichever model it holds.
    ///
    /// - Throws: ``ModelUnavailability``, when the provider refuses the key, can't be reached, or
    ///   answers something else; `CancellationError`, when it's cancelled.
    public func availableModels(key: String?) async throws -> [AgentModelID] {
        let names: [String]
        switch self {
        case .appleSystem:
            names = ["default"]
        #if Llama
            case .llamaCPP:
                names = []
        #endif
        case .server(.ollama, let address):
            names = try await OllamaLanguageModel.availableModels(baseURL: address.url, apiKey: key)
        case .server(.openAICompatible, let address):
            names = try await OpenAILanguageModel.availableModels(baseURL: address.url, apiKey: key)
        case .cloud(let provider):
            guard let key else { throw ModelUnavailability(kind: .keyNeeded) }
            switch provider {
            case .openAI: names = try await OpenAILanguageModel.availableModels(apiKey: key)
            case .anthropic: names = try await AnthropicLanguageModel.availableModels(apiKey: key)
            case .gemini: names = try await GeminiLanguageModel.availableModels(apiKey: key)
            }
        }
        return names.map(AgentModelID.init(rawValue:))
    }

    /// Whether `model` can be used here now, asked with `key`: a server or a cloud, whether it takes
    /// the key and has the model; this machine, whether it can run it. When it can, what checking
    /// it learned, such as the model's context size.
    public func checkAvailability(of model: AgentModelID, key: String?) async throws(CancellationError)
        -> ModelAvailability
    {
        switch self {
        case .appleSystem:
            #if canImport(FoundationModels)
                return try await SystemLanguageModel().checkAvailability()
            #else
                return .unavailable(ModelUnavailability(kind: .deviceNotEligible))
            #endif
        #if Llama
            case .llamaCPP(let file, let layers):
                return try await LlamaLanguageModel(modelPath: file, gpuLayers: layers).checkAvailability()
        #endif
        case .server, .cloud:
            guard let languageModel = remoteLanguageModel(model.rawValue, key: key, transport: makeDefaultTransport())
            else { return .unavailable(ModelUnavailability(kind: .keyNeeded)) }
            return try await languageModel.checkAvailability()
        }
    }

    /// AnyLanguageModel's model for `model` on a server or in a cloud, asked with `key` and sent
    /// through `transport`: none on this machine, and none for a cloud without a key.
    func remoteLanguageModel(_ model: String, key: String?, transport: any HTTPTransport) -> (any LanguageModel)? {
        switch self {
        case .appleSystem:
            return nil
        #if Llama
            case .llamaCPP:
                return nil
        #endif
        case .server(let software, let address):
            let url = address.url
            switch (software, key) {
            case (.ollama, let key?):
                return OllamaLanguageModel(baseURL: url, apiKey: key, model: model, transport: transport)
            case (.ollama, nil):
                return OllamaLanguageModel(baseURL: url, model: model, transport: transport)
            case (.openAICompatible(.chatCompletions), let key?):
                return OpenAILanguageModel(baseURL: url, apiKey: key, model: model, transport: transport)
            case (.openAICompatible(.chatCompletions), nil):
                return OpenAILanguageModel(baseURL: url, model: model, transport: transport)
            case (.openAICompatible(.responses), let key?):
                return OpenResponsesLanguageModel(baseURL: url, apiKey: key, model: model, transport: transport)
            case (.openAICompatible(.responses), nil):
                return OpenResponsesLanguageModel(baseURL: url, model: model, transport: transport)
            }
        case .cloud(let provider):
            guard let key else { return nil }
            switch provider {
            case .openAI: return OpenAILanguageModel(apiKey: key, model: model, transport: transport)
            case .anthropic: return AnthropicLanguageModel(apiKey: key, model: model, transport: transport)
            case .gemini: return GeminiLanguageModel(apiKey: key, model: model, transport: transport)
            }
        }
    }
}

extension AgentProviderConfiguration {
    /// Where it runs and how it's reached.
    public var location: ModelLocation {
        switch self {
        case .local(.appleSystem): .appleSystem
        #if Llama
            case .local(.llamaCPP(let file, let layers, _)): .llamaCPP(file: file, gpuLayers: layers)
        #endif
        case .server(let server): .server(server.software, server.address)
        case .cloud(let account): .cloud(account.provider)
        }
    }
}

extension ContextWindow {
    /// A bot's window at `location`, for a model that takes `modelTakes` tokens, when that's known:
    /// `typed`, when the model takes that many; none typed, as many as the model takes, and on an
    /// Ollama server, which gives a model memory for its whole window, no more than ``standard``.
    public static func chosen(typed: ContextWindow?, modelTakes: Int?, at location: ModelLocation)
        throws(ContextWindowChoiceError) -> ContextWindow
    {
        if let typed {
            if let modelTakes, typed.tokens > modelTakes { throw .aboveModel(typed: typed.tokens, model: modelTakes) }
            return typed
        }
        guard let modelTakes, let own = try? ContextWindow(tokens: modelTakes) else { throw .unknown }
        if case .server(.ollama, _) = location { return Swift.min(own, .standard) }
        return own
    }
}

public enum ContextWindowChoiceError: Error, Equatable, Sendable {
    /// More was typed than the model takes.
    case aboveModel(typed: Int, model: Int)
    /// None was typed, and the model's own isn't known.
    case unknown
}
