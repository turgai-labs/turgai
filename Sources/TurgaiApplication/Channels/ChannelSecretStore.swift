import TurgaiPersistence
import TurgaiDomain

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// Stores credentials for channel transports. Credentials are deliberately
/// independent from the channel catalog and from the Channel actor state.
public actor ChannelSecretStore {
    private let files: FileClient

    public init(files: FileClient) {
        self.files = files
    }

    public func setToken(for channelID: UUID, token: String) throws {
        let trimmed = token.trimmed()
        guard !trimmed.isEmpty else {
            throw TurgaiChannelError.invalidToken
        }
        try files.saveSecret(trimmed, at: tokenPath(for: channelID))
    }

    public func token(for channelID: UUID) -> String? {
        (try? files.loadSecret(at: tokenPath(for: channelID))) ?? nil
    }

    public func hasToken(for channelID: UUID) -> Bool {
        token(for: channelID) != nil
    }

    public func remove(for channelID: UUID) throws {
        try files.delete(at: tokenPath(for: channelID))
    }

    private func tokenPath(for channelID: UUID) -> String {
        "channels/\(channelID.uuidString).token"
    }
}
