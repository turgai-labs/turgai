import Foundation
import Hail
import TurgaiDomain

public struct WebSessionID: Hashable, Sendable, Codable, Identifiable {
    public let rawValue: UUID

    public var id: UUID { rawValue }

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

/// Gives the web application access to the live conversation connections
/// after the application runtime has finished booting.
public actor TurgaiWebChatBridge {
    private var connections: TurgaiConnections?

    public init() {}

    public func install(_ connections: TurgaiConnections) {
        self.connections = connections
    }

    public func openSession(id: WebSessionID) async throws -> TurgaiConnections.WebSession {
        guard let connections else {
            throw TurgaiWebChatBridgeError.runtimeUnavailable
        }
        return await connections.addWebSession(id: id)
    }

    public func conversationHistory(
        for conversationID: ConversationID,
        role: TurgaiAgentRole
    ) async throws -> [ChatMessage] {
        guard let connections else {
            throw TurgaiWebChatBridgeError.runtimeUnavailable
        }
        return try await connections.conversationHistory(
            for: conversationID,
            role: role
        )
    }
}

public enum TurgaiWebChatBridgeError: Error, Sendable {
    case runtimeUnavailable
}
