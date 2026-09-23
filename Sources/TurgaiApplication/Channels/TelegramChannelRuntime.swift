import DistributedCluster
import Foundation
import Logging
import TurgaiDomain
import TurgaiTelegram

public struct TelegramChannelRuntime: Sendable {
    fileprivate let channelID: UUID
    fileprivate let configuration: TelegramChannelConfig
    fileprivate let client: TelegramAPIClient
    fileprivate let dependencies: TurgaiChannelRuntimeDependencies
    fileprivate let approval: TelegramToolApproval
    fileprivate let readState: @Sendable () async throws -> TelegramChannelState
    fileprivate let emit: @Sendable (TelegramChannelEvent) async throws -> Void
    fileprivate let logger: Logger
}

private enum TelegramChannelRuntimeStartError: Error {
    case missingToken(UUID)
}

extension TelegramProvider {
    public static func makeRuntime(
        configuration: ChannelConfiguration<TelegramProvider>,
        state: TelegramChannelState,
        actorSystem: ClusterSystem,
        readState: @escaping @Sendable () async throws -> TelegramChannelState,
        emit: @escaping @Sendable (TelegramChannelEvent) async throws -> Void
    ) async throws -> TelegramChannelRuntime {
        let channelID = configuration.id
        let dependencies = try await actorSystem.turgaiChannelRuntime.dependencies()
        guard let token = await dependencies.secrets.token(for: channelID) else {
            throw TelegramChannelRuntimeStartError.missingToken(channelID)
        }
        let client = try TelegramAPIClient.live(token: token)
        return TelegramChannelRuntime(
            channelID: channelID,
            configuration: configuration.provider,
            client: client,
            dependencies: dependencies,
            approval: TelegramToolApproval(client: client),
            readState: readState,
            emit: emit,
            logger: actorSystem.log
        )
    }

    public static func run(_ runtime: TelegramChannelRuntime) async throws {
        let state = try await runtime.readState()
        let channel = ChannelID(
            provider: providerID,
            instanceID: runtime.channelID.uuidString
        )
        let persistedConversationIDs = try await runtime.dependencies
            .loadPersistedConversationIDs()
            .filter { conversationID in
                guard conversationID.channel == channel,
                    let chatID = Int64(conversationID.externalAddress.rawValue)
                else { return false }
                return runtime.configuration.chatIDs.isEmpty
                    || runtime.configuration.chatIDs.contains(chatID)
            }
        let service = TelegramService(
            client: runtime.client,
            allowedChatIDs: Set(runtime.configuration.chatIDs),
            initialOffset: state.cursor.offset,
            checkpointOffset: { offset in
                try await runtime.emit(.cursorAdvanced(offset))
            },
            connections: runtime.dependencies.connections,
            channelID: runtime.channelID,
            attachmentResolver: runtime.dependencies.attachments,
            attachmentOwner: runtime.channelID,
            logger: runtime.logger,
            persistedConversationIDs: persistedConversationIDs,
            callbackHandler: { await runtime.approval.handle($0) }
        )

        try await service.run()
    }

    public static func decideApproval(
        _ request: ChannelApprovalRequest,
        using runtime: TelegramChannelRuntime
    ) async throws -> ApprovalDecision {
        try await runtime.approval.decide(request)
    }
}
