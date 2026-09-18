/// Stable role used to resolve a Turgai conversation's agent transcript.
public struct TurgaiAgentRole: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let conversation = Self(rawValue: "conversation")

    public static func profile(_ profileID: String) -> Self {
        Self(rawValue: profileID)
    }
}
