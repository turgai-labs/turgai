/// What a client needs to know before showing the chat, served without
/// authentication at `GET /api/v1/status`.
public struct TurgaiServerStatus: Codable, Hashable, Sendable {
    public enum Setup: String, Codable, Hashable, Sendable {
        /// Onboarding hasn't finished: no admin, storage, or default bot yet.
        case pending
        /// Ready for chat.
        case complete
    }

    public let setup: Setup

    public init(setup: Setup) {
        self.setup = setup
    }
}
