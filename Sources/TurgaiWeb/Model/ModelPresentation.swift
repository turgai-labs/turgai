import Hail
import TurgaiAgents
import TurgaiApplication
import TurgaiDomain

#if canImport(FoundationModels)
    import FoundationModels
#endif

public enum TurgaiModelPresentation {
    public static func displayName(for model: AgentModel) -> String {
        guard model.provider == .system else { return model.identifier }
        return "Apple Intelligence · \(appleSystemModelName)"
    }

    public static var appleSystemModelName: String {
        #if canImport(FoundationModels)
            if #available(macOS 27.0, *) {
                return SystemLanguageModel.default.variant.displayName
            }
        #endif
        return "Apple Foundation Model"
    }
}

extension AgentProvider {
    /// The providers to choose from here: Apple's on-device model only where it runs.
    static var offered: [AgentProvider] {
        #if canImport(FoundationModels)
            allCases
        #else
            allCases.filter { $0 != .appleSystem }
        #endif
    }

    var title: String {
        switch self {
        case .appleSystem: "Apple Intelligence"
        #if Llama
            case .llamaCPP: "llama.cpp"
        #endif
        case .ollama: "Ollama"
        case .openAICompatible: "OpenAI-compatible server"
        case .openAI: "OpenAI"
        case .anthropic: "Anthropic"
        case .gemini: "Gemini"
        }
    }
}

extension AgentProvider.Kind {
    var title: String {
        switch self {
        case .local: "On this machine"
        case .server: "On a server"
        case .cloud: "In a provider's cloud"
        }
    }
}
