import Hail
import TurgaiDomain

extension AgentProvider {
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
