import AnyLanguageModel
import Hail
import TurgaiDomain

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

    /// Whether `model` runs in Ollama's cloud: there, or passed on to it by a server of your own,
    /// which names its cloud models so.
    public func runsInOllamasCloud(_ model: AgentModelID) -> Bool {
        guard case .server(.ollama, let address) = self else { return false }
        let name = model.rawValue
        return address.isSameServer(as: .ollamaCloud) || name.hasSuffix(":cloud") || name.hasSuffix("-cloud")
    }

    /// Whether a key for `other` is one for it too: the same cloud, or the same server.
    public func sharesKey(with other: ModelLocation) -> Bool {
        switch (self, other) {
        case (.cloud(let one), .cloud(let another)): one == another
        case (.server(_, let one), .server(_, let another)): one.isSameServer(as: another)
        default: false
        }
    }

    /// A bot's `model` here, reached with the key `key` refers to, with the context it gets: where
    /// you choose, `typed`, when the model takes that many, or else as many as it takes, and on an
    /// Ollama server, which keeps memory for the whole window, no more than
    /// ``ContextWindow/standard``; anywhere else the provider's own window, `modelTakes` when the
    /// provider says it.
    public func configuration(
        key: AgentCredentialReference?, model: AgentModelID, typed: ContextWindow?, modelTakes: Int?
    ) throws(ModelConfigurationError) -> AgentProviderConfiguration {
        switch self {
        case .appleSystem:
            return .local(.appleSystem)
        #if Llama
            case .llamaCPP(let file, let layers):
                let window = try Self.chosen(typed: typed, modelTakes: modelTakes, atMost: nil)
                return .local(.llamaCPP(file: file, gpuLayers: layers, contextWindow: window))
        #endif
        case .server(let software, let address):
            let context: ModelContext =
                choosesWindow(for: model)
                ? .chosen(try Self.chosen(typed: typed, modelTakes: modelTakes, atMost: .standard))
                : .providers(ProviderWindow(modelTakes: modelTakes))
            return .server(ModelServer(software: software, address: address, key: key, context: context))
        case .cloud(let provider):
            guard let key else { throw .keyNeeded }
            return .cloud(CloudAccount(provider: provider, key: key, window: ProviderWindow(modelTakes: modelTakes)))
        }
    }

    /// The window you choose: `typed`, when the model takes that many; none typed, as many as it
    /// takes, no more than `atMost`.
    private static func chosen(typed: ContextWindow?, modelTakes: Int?, atMost: ContextWindow?)
        throws(ModelConfigurationError) -> ContextWindow
    {
        let own = modelTakes.flatMap { try? ContextWindow(tokens: $0) }
        if let typed {
            if let own, typed > own { throw .windowAboveModel(typed: typed.tokens, model: own.tokens) }
            return typed
        }
        guard let own else { throw .windowUnknown }
        return atMost.map { Swift.min(own, $0) } ?? own
    }

    /// How Hail asks about models here, with `key`: none for a cloud without one.
    private func access(key: String?) -> ModelAccess? {
        switch self {
        case .appleSystem:
            return .system
        #if Llama
            case .llamaCPP(let file, _):
                return .llama(modelPath: file)
        #endif
        case .server(.ollama, let address):
            return .ollama(baseURL: address.url, apiKey: key)
        case .server(.openAICompatible, let address):
            return .openAICompatible(baseURL: address.url, apiKey: key)
        case .cloud(let provider):
            guard let key else { return nil }
            switch provider {
            case .openAI: return .openAI(apiKey: key)
            case .anthropic: return .anthropic(apiKey: key)
            case .gemini: return .gemini(apiKey: key)
            }
        }
    }

    /// The models it offers, by their IDs, as Hail lists them, asked with `key`: Apple's on-device
    /// model is its one model; a GGUF file is whichever model it holds.
    ///
    /// - Throws: ``ModelUnavailability``, when the provider refuses the key, can't be reached, or
    ///   answers something else; `CancellationError`, when it's cancelled.
    public func availableModels(key: String?) async throws -> [AgentModelID] {
        guard let access = access(key: key) else { throw ModelUnavailability(kind: .keyNeeded) }
        return try await access.availableModels().sorted(by: Self.naturally).map(AgentModelID.init(rawValue:))
    }

    /// Whether `one` comes before `other` as a person reads them: letters regardless of case, and
    /// numbers by their value, so `qwen3:8b` before `qwen3:32b`.
    static func naturally(_ one: String, _ other: String) -> Bool {
        /// `name`'s runs of digits and of everything else, lowercased.
        func runs(_ name: String) -> [Substring] {
            let name = Substring(name.lowercased())
            guard !name.isEmpty else { return [] }
            var runs: [Substring] = []
            var start = name.startIndex
            for index in name.indices.dropFirst()
            where name[index].isNumber != name[name.index(before: index)].isNumber {
                runs.append(name[start..<index])
                start = index
            }
            runs.append(name[start...])
            return runs
        }
        let (ones, others) = (runs(one), runs(other))
        for (a, b) in zip(ones, others) where a != b {
            if let x = Int(a), let y = Int(b), x != y { return x < y }
            return a < b
        }
        return ones.count < others.count
    }

    /// Whether `model` can be used here now, asked with `key`: a server or a cloud, whether it takes
    /// the key and has the model; this machine, whether it can run it. When it can, what checking
    /// it learned, such as the model's context size. Ollama's cloud shows its models to anyone,
    /// but runs them only for a key, so there one is needed.
    public func checkAvailability(of model: AgentModelID, key: String?) async throws(CancellationError)
        -> ModelAvailability
    {
        if case .server(.ollama, let address) = self, address.isSameServer(as: .ollamaCloud), key == nil {
            return .unavailable(ModelUnavailability(kind: .keyNeeded))
        }
        guard let access = access(key: key) else { return .unavailable(ModelUnavailability(kind: .keyNeeded)) }
        return try await access.checkAvailability(of: model.rawValue)
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
            // A server that takes no key is given an empty one, and sent none.
            switch (software, key) {
            case (.ollama, let key?):
                return OllamaLanguageModel(baseURL: url, apiKey: key, model: model, transport: transport)
            case (.ollama, nil):
                return OllamaLanguageModel(baseURL: url, model: model, transport: transport)
            case (.openAICompatible(.chatCompletions), _):
                return OpenAILanguageModel(baseURL: url, apiKey: key ?? "", model: model, transport: transport)
            case (.openAICompatible(.responses), _):
                return OpenResponsesLanguageModel(baseURL: url, apiKey: key ?? "", model: model, transport: transport)
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

extension ModelLocation {
    /// Whether how much context `model` gets is yours to choose: your own Ollama server runs it,
    /// unless it passes it on to Ollama's cloud; or llama.cpp loads it here. Anywhere else the
    /// provider runs it with its own window.
    public func choosesWindow(for model: AgentModelID) -> Bool {
        switch self {
        #if Llama
            case .llamaCPP: return true
        #endif
        case .server(.ollama, _): return !runsInOllamasCloud(model)
        default: return false
        }
    }
}

public enum ModelConfigurationError: Error, Equatable, Sendable {
    /// A cloud is asked with a key, and none was given.
    case keyNeeded
    /// More was typed than the model takes.
    case windowAboveModel(typed: Int, model: Int)
    /// Where the window is yours to choose, none was typed, and the model's own isn't known.
    case windowUnknown
}
