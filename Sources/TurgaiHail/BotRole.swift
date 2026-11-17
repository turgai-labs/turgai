import TurgaiDomain

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

extension BotID {
    /// What Hail calls the bot's agents: one in each conversation it answers in. Its id's digits
    /// only, since Hail reads an agent's role up to its id's first hyphen.
    public var role: String { rawValue.uuidString.filter { $0 != "-" } }

    /// The bot whose agents Hail calls `role`: none for an agent that isn't a bot's.
    public init?(role: String) {
        guard role.count == 32, role.allSatisfy(\.isHexDigit) else { return nil }
        let digits = Array(role)
        let written = [0..<8, 8..<12, 12..<16, 16..<20, 20..<32].map { String(digits[$0]) }.joined(separator: "-")
        guard let id = UUID(uuidString: written) else { return nil }
        self.init(rawValue: id)
    }
}
