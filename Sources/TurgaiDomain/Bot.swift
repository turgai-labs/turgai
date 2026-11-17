#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// A bot, by the id it's given as it's added: it stays the same whatever it's called.
public struct BotID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    /// The bot written as its id is: none for anything else.
    public init?(_ written: String) {
        guard let id = UUID(uuidString: written) else { return nil }
        self.init(rawValue: id)
    }

    public var description: String { rawValue.uuidString }
}

/// What a bot is called, as people see and mention it.
public struct BotName: Hashable, Codable, Sendable, CustomStringConvertible {
    public static let maximumLength = 80

    public let rawValue: String

    /// The name `written`, without the space around it: none when there's nothing, or too much.
    public init?(_ written: String) {
        let name = written.trimmed()
        guard !name.isEmpty, name.count <= Self.maximumLength else { return nil }
        self.rawValue = name
    }

    public var description: String { rawValue }
}

/// A model, by the name where it runs knows it by.
public struct ModelName: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String

    /// The name `written`, without the space around it: none when there's nothing.
    public init?(_ written: String) {
        let name = written.trimmed()
        guard !name.isEmpty else { return nil }
        self.rawValue = name
    }

    public var description: String { rawValue }
}

/// What thinks for a bot: where it runs and how it's reached, and which of the models there.
public struct BotModel: Hashable, Codable, Sendable {
    public var location: AgentProviderConfiguration
    public var name: ModelName

    public init(location: AgentProviderConfiguration, name: ModelName) {
        self.location = location
        self.name = name
    }
}

/// A bot of a space: who it is, how it behaves, and what thinks for it.
public struct Bot: Hashable, Codable, Sendable, Identifiable {
    public let id: BotID
    public var name: BotName
    public var instructions: String
    public var model: BotModel

    public init(id: BotID = BotID(), name: BotName, instructions: String, model: BotModel) {
        self.id = id
        self.name = name
        self.instructions = instructions
        self.model = model
    }
}
