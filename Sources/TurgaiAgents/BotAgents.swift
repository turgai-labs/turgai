import Hail
import TurgaiDomain

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

extension BotModel {
    /// Hail's name for it.
    public var agentModel: AgentModel {
        get throws {
            try AgentModel(provider: location.provider.modelProvider, id: AgentModelID(rawValue: name.rawValue))
        }
    }
}
