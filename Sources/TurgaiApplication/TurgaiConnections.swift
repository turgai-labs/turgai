import AsyncAlgorithms
import DistributedCluster
import Hail
import ServiceLifecycle
import TurgaiDomain

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

private enum OutboundDeliveryResult: Sendable {
    case delivered
    case failed(String)
    case cancelled
}

private struct OutboundDeliveryError: Error, Sendable, Equatable {
    let message: String
}

private actor OutboundDeliveryReceipt {
    private var result: OutboundDeliveryResult?
    private var waiters: [UUID: CheckedContinuation<OutboundDeliveryResult, Never>] = [:]
    private var cancelledWaiters: Set<UUID> = []

    public func wait() async throws {
        let waiterID = UUID()
        let result = await withTaskCancellationHandler {
            await register(waiterID)
        } onCancel: {
            Task {
                await self.cancel(waiterID)
            }
        }

        switch result {
        case .delivered:
            return
        case .failed(let message):
            throw OutboundDeliveryError(message: message)
        case .cancelled:
            throw CancellationError()
        }
    }

    func delivered() {
        resolve(.delivered)
    }

    func failed(_ message: String) {
        resolve(.failed(message))
    }

    private func register(
        _ waiterID: UUID
    ) async -> OutboundDeliveryResult {
        if let result {
            return result
        }
        if cancelledWaiters.remove(waiterID) != nil {
            return .cancelled
        }
        return await withCheckedContinuation { continuation in
            waiters[waiterID] = continuation
        }
    }

    private func cancel(_ waiterID: UUID) {
        guard result == nil else { return }
        guard let waiter = waiters.removeValue(forKey: waiterID) else {
            cancelledWaiters.insert(waiterID)
            return
        }
        waiter.resume(returning: .cancelled)
    }

    private func resolve(_ result: OutboundDeliveryResult) {
        guard self.result == nil else { return }
        self.result = result
        cancelledWaiters.removeAll()
        let waiters = Array(self.waiters.values)
        self.waiters.removeAll()
        for waiter in waiters {
            waiter.resume(returning: result)
        }
    }
}

public struct OutboundDelivery: Sendable {
    public let id = UUID()
    public let event: OutboundEvent
    private let receipt = OutboundDeliveryReceipt()

    public init(event: OutboundEvent) {
        self.event = event
    }

    public func wait() async throws {
        try await receipt.wait()
    }

    public func delivered() async {
        await receipt.delivered()
    }

    public func failed(_ message: String) async {
        await receipt.failed(message)
    }
}

/// Identifies how a live session entered Turgai. A Telegram session belongs
/// to one channel actor; a web session has no provider-channel binding.
public enum LiveSessionSource: Sendable, Equatable {
    case web
    case channel(UUID)
}

private enum LiveSessionRoutingError: Error {
    case channelIdentityMismatch
    case channelUnavailable
    case unavailableProfile(String)
}

private actor OutboundDeliveryRegistry {
    private var pending: [UUID: OutboundDelivery] = [:]

    func insert(_ delivery: OutboundDelivery) {
        pending[delivery.id] = delivery
    }

    func remove(_ delivery: OutboundDelivery) {
        pending[delivery.id] = nil
    }

    func failAll() async {
        let deliveries = Array(pending.values)
        pending.removeAll()
        for delivery in deliveries {
            await delivery.failed("The outbound connection closed.")
        }
    }
}

/// Owns Turgai's live client sessions.
///
/// This follows StagehandConnections: channel services provide an inbound
/// stream to `addLiveSession`, the factory creates a live session, and the
/// returned outbound stream is consumed by that channel service.
public actor TurgaiConnections: Service {
    public struct LiveSessionConnection: Sendable {
        public let output: AsyncStream<OutboundDelivery>
        let handle: UUID

        init(output: AsyncStream<OutboundDelivery>, handle: UUID) {
            self.output = output
            self.handle = handle
        }
    }

    public struct WebSession: Sendable {
        public let input: AsyncChannel<ConversationInputDelivery>
        public let output: AsyncStream<OutboundDelivery>

        init(
            input: AsyncChannel<ConversationInputDelivery>,
            output: AsyncStream<OutboundDelivery>
        ) {
            self.input = input
            self.output = output
        }
    }

    enum Connection: Identifiable, Sendable {
        case live(LiveSession)

        var id: String {
            switch self {
            case .live(let session): session.id
            }
        }

        var handle: UUID {
            switch self {
            case .live(let session): session.handle
            }
        }

        func finish() async {
            switch self {
            case .live(let session): await session.finish()
            }
        }
    }

    /// Thread-safe registry of currently active sessions.
    actor OutboundConnections {
        private var connections: [String: Connection] = [:]

        func add(_ connection: Connection) async {
            let previous = connections.updateValue(connection, forKey: connection.id)
            if let previous {
                await previous.finish()
            }
        }

        func remove(_ connection: Connection) {
            guard connections[connection.id]?.handle == connection.handle else { return }
            connections.removeValue(forKey: connection.id)
        }

        func finish(id: String, handle: UUID) async {
            guard connections[id]?.handle == handle,
                let connection = connections.removeValue(forKey: id)
            else { return }
            await connection.finish()
        }

        func finishAll() async {
            let connections = Array(connections.values)
            self.connections.removeAll()
            for connection in connections {
                await connection.finish()
            }
        }
    }

    private let actorSystem: ClusterSystem
    private let agentProfiles: TurgaiAgentProfileStore
    private let connectionStream: AsyncStream<Connection>
    private let connectionContinuation: AsyncStream<Connection>.Continuation
    private let outboundConnections = OutboundConnections()

    public init(
        actorSystem: ClusterSystem,
        agentProfiles: TurgaiAgentProfileStore
    ) {
        self.actorSystem = actorSystem
        self.agentProfiles = agentProfiles
        (self.connectionStream, self.connectionContinuation) =
            AsyncStream<Connection>.makeStream()
    }

    /// Creates one live Turgai session for one external logical connection.
    ///
    /// The caller owns the input stream and receives the output stream. This
    /// is the same factory boundary as StagehandConnections.addLiveSession.
    public func addLiveSession(
        id: String,
        source: LiveSessionSource,
        inbound: AsyncChannel<ConversationInputDelivery>
    ) async -> LiveSessionConnection {
        let session = LiveSession(
            id: id,
            actorSystem: actorSystem,
            inbound: inbound,
            agentProfiles: agentProfiles,
            source: source
        )
        await outboundConnections.add(.live(session))
        connectionContinuation.yield(.live(session))
        return LiveSessionConnection(output: session.output, handle: session.handle)
    }

    public func addWebSession(id: WebSessionID) async -> WebSession {
        let inbound = AsyncChannel<ConversationInputDelivery>()
        let session = await addLiveSession(
            id: id.rawValue.uuidString,
            source: .web,
            inbound: inbound
        )
        return WebSession(input: inbound, output: session.output)
    }

    public func conversationHistory(
        for conversationID: ConversationID,
        role: TurgaiAgentRole
    ) async throws -> [ConversationHistoryEntry] {
        let conversation = try await Conversation.resolve(
            on: actorSystem,
            conversationID: conversationID,
            agentDirectoryID: "agent-directory",
            agentRole: role.rawValue,
            memoryExtraction: await agentProfiles.memoryExtractionConfiguration(
                forProfileID: role.rawValue
            )
        )
        return try await conversation.history()
    }

    public func conversationStatus(
        for conversationID: ConversationID,
        role: TurgaiAgentRole
    ) async throws -> ConversationStatus {
        let conversation = try await Conversation.resolve(
            on: actorSystem,
            conversationID: conversationID,
            agentDirectoryID: "agent-directory",
            agentRole: role.rawValue,
            memoryExtraction: await agentProfiles.memoryExtractionConfiguration(
                forProfileID: role.rawValue
            )
        )
        return try await conversation.currentStatus()
    }

    /// Stops accepting sessions. Existing session workers are cancelled by
    /// the task group and finish their sessions after their input stream ends.
    public func stop() async {
        connectionContinuation.finish()
        await outboundConnections.finishAll()
    }

    public func run() async throws {
        await withTaskCancellationOrGracefulShutdownHandler(
            operation: {
                await withDiscardingTaskGroup { group in
                    for await connection in self.connectionStream {
                        group.addTask {
                            await self.handleMessages(from: connection)
                            await self.outboundConnections.remove(connection)
                            await connection.finish()
                        }
                    }
                    group.cancelAll()
                }
            },
            onCancelOrGracefulShutdown: {
                Task { await self.stop() }
            }
        )
    }

    /// Ends one transport-owned session. The session is removed from the
    /// active set before it is finished, so a replacement with the same
    /// external ID cannot be closed by a late cleanup from the old session.
    public func finishLiveSession(id: String, handle: UUID) async {
        await outboundConnections.finish(id: id, handle: handle)
    }

    private func handleMessages(from connection: Connection) async {
        switch connection {
        case .live(let session):
            await session.run()
        }
    }
}

/// One live Turgai session, equivalent to Stagehand's LiveSession.
///
/// It is channel-neutral: Telegram, a web client, or another adapter can
/// feed `ConversationInput` and consume `OutboundEvent` without leaking its
/// transport types into this layer.
private enum UserCommand {
    case memory
    case forget
    case context
    case diagnose
    case reminders
    case tasks
    case pauseTask(String)
    case unpauseTask(String)
    case cancelTask(String)
    case cancelReminder(String)
}

actor LiveSession {
    /// Unbounded delivery buffer. Unlike `AsyncChannel` (a rendezvous that
    /// suspends `send` until a consumer iterates), yielding into this stream
    /// never waits: a slow or dead client can only fill its own buffer, and
    /// the only backpressure left in the system lives in the route's socket
    /// writer, where it belongs.
    typealias OutputStream = AsyncStream<OutboundDelivery>

    let id: String
    let handle = UUID()
    let output: OutputStream

    private let actorSystem: ClusterSystem
    private let inbound: AsyncChannel<ConversationInputDelivery>
    private let outputContinuation: OutputStream.Continuation
    private let agentProfiles: TurgaiAgentProfileStore
    private let source: LiveSessionSource
    private let conversationConnection: ConversationConnection
    private let deliveryRegistry: OutboundDeliveryRegistry
    private var conversations: [ConversationID: Conversation] = [:]
    private var finished = false

    init(
        id: String,
        actorSystem: ClusterSystem,
        inbound: AsyncChannel<ConversationInputDelivery>,
        agentProfiles: TurgaiAgentProfileStore,
        source: LiveSessionSource
    ) {
        self.id = id
        self.actorSystem = actorSystem
        self.inbound = inbound
        self.agentProfiles = agentProfiles
        self.source = source
        let (output, outputContinuation) = OutputStream.makeStream()
        self.output = output
        self.outputContinuation = outputContinuation
        self.deliveryRegistry = OutboundDeliveryRegistry()
        let deliveryRegistry = self.deliveryRegistry
        self.conversationConnection = ConversationConnection(
            actorSystem: actorSystem,
            onEvent: { event in
                let delivery = OutboundDelivery(event: event)
                await deliveryRegistry.insert(delivery)
                outputContinuation.yield(delivery)
                await deliveryRegistry.remove(delivery)
            }
        )
    }

    func run() async {
        for await delivery in inbound {
            if Task.isCancelled {
                await delivery.receipt.cancel()
                return
            }
            if await handle(delivery.input) {
                await delivery.receipt.acknowledge()
            } else {
                await delivery.receipt.reject()
            }
        }
    }

    func finish() async {
        guard !self.finished else { return }
        self.finished = true
        // Unblock the output consumer and fail any deliveries Telegram's
        // pipeline still considers in flight.
        self.outputContinuation.finish()
        await self.deliveryRegistry.failAll()
        for conversation in self.conversations.values {
            try? await conversation.removeConnection(conversationConnection)
        }
        self.conversations.removeAll()
    }

    private func handle(_ input: ConversationInput) async -> Bool {
        switch input {
        case .connect(let conversationID):
            do {
                let role = try await self.resolvedAgentRole(for: conversationID)
                let conversation = try await self.resolveConversation(
                    conversationID,
                    agentRole: role
                )
                try await self.attach(
                    to: conversation,
                    conversationID: conversationID
                )
                return true
            } catch {
                self.actorSystem.log.error(
                    "Could not connect persisted conversation",
                    metadata: [
                        "conversationID": .string(conversationID.stableKey),
                        "error": .string(String(describing: error)),
                    ]
                )
                return false
            }

        case .message(let message, let turnID):
            do {
                let user = try await User.resolve(
                    on: actorSystem,
                    userID: message.userID
                )
                try await user.link(participantID: message.participantID)

                let agentRole = try await self.resolvedAgentRole(for: message.conversationID)
                let conversation = try await self.resolveConversation(
                    message.conversationID,
                    agentRole: agentRole
                )
                try await self.attach(
                    to: conversation,
                    conversationID: message.conversationID
                )
                try await conversation.send(
                    message,
                    turnID: turnID,
                    configuration: Conversation.TurnConfiguration(
                        agentRole: agentRole,
                        memoryExtraction: await agentProfiles.memoryExtractionConfiguration(
                            forProfileID: agentRole
                        )
                    ),
                )
                return true
            } catch {
                await publish(
                    .reply(
                        .failed(
                            conversationID: message.conversationID,
                            turnID: turnID,
                            message: String(describing: error)
                        )
                    )
                )
                return false
            }

        case .reset(let conversationID):
            do {
                let role = try await resolvedAgentRole(for: conversationID)
                let conversation = try await resolveConversation(
                    conversationID,
                    agentRole: role
                )
                try await attach(
                    to: conversation,
                    conversationID: conversationID
                )
                try await conversation.reset()
                return true
            } catch {
                await publish(
                    .reply(
                        .failed(
                            conversationID: conversationID,
                            turnID: nil,
                            message: String(describing: error)
                        )
                    )
                )
                return false
            }

        case .approval(let conversationID, let approvalID, let decision):
            // Only a conversation this session is attached to hears its answer.
            guard let conversation = conversations[conversationID] else { return false }
            do {
                try await conversation.decideApproval(approvalID, decision: decision)
                return true
            } catch {
                return false
            }

        case .memory(let conversationID, let participantID, let userID):
            return await handleUserCommand(
                .memory,
                conversationID: conversationID,
                participantID: participantID,
                userID: userID
            )

        case .forget(let conversationID, let participantID, let userID):
            return await handleUserCommand(
                .forget,
                conversationID: conversationID,
                participantID: participantID,
                userID: userID
            )

        case .context(let conversationID, let participantID, let userID):
            return await handleUserCommand(
                .context,
                conversationID: conversationID,
                participantID: participantID,
                userID: userID
            )

        case .diagnose(let conversationID, let participantID, let userID):
            return await handleUserCommand(
                .diagnose,
                conversationID: conversationID,
                participantID: participantID,
                userID: userID
            )

        case .command(let command):
            switch command {
            case .reminders(let conversationID, let participantID, let userID):
                return await handleUserCommand(
                    .reminders,
                    conversationID: conversationID,
                    participantID: participantID,
                    userID: userID
                )
            case .tasks(let conversationID, let participantID, let userID):
                return await handleUserCommand(
                    .tasks,
                    conversationID: conversationID,
                    participantID: participantID,
                    userID: userID
                )
            case .pauseTask(let id, let conversationID, let participantID, let userID):
                return await handleUserCommand(
                    .pauseTask(id),
                    conversationID: conversationID,
                    participantID: participantID,
                    userID: userID
                )
            case .unpauseTask(let id, let conversationID, let participantID, let userID):
                return await handleUserCommand(
                    .unpauseTask(id),
                    conversationID: conversationID,
                    participantID: participantID,
                    userID: userID
                )
            case .cancelTask(let id, let conversationID, let participantID, let userID):
                return await handleUserCommand(
                    .cancelTask(id),
                    conversationID: conversationID,
                    participantID: participantID,
                    userID: userID
                )
            case .cancelReminder(let id, let conversationID, let participantID, let userID):
                return await handleUserCommand(
                    .cancelReminder(id),
                    conversationID: conversationID,
                    participantID: participantID,
                    userID: userID
                )
            }
        }
    }

    private func handleUserCommand(
        _ command: UserCommand,
        conversationID: ConversationID,
        participantID: ParticipantID,
        userID: TurgaiDomain.UserID
    ) async -> Bool {
        do {
            let user = try await User.resolve(on: actorSystem, userID: userID)
            try await user.link(participantID: participantID)

            let role = try await self.resolvedAgentRole(for: conversationID)
            let conversation = try await self.resolveConversation(
                conversationID,
                agentRole: role
            )
            try await self.attach(
                to: conversation,
                conversationID: conversationID
            )

            switch command {
            case .memory:
                try await conversation.showMemory(for: userID)
            case .forget:
                try await conversation.forgetMemory(for: userID)
            case .context:
                try await conversation.showContext()
            case .diagnose:
                try await conversation.showDiagnostics(for: userID)
            case .reminders:
                try await conversation.showReminders()
            case .tasks:
                try await conversation.showTasks()
            case .pauseTask(let id):
                try await conversation.pauseTask(id: id)
            case .unpauseTask(let id):
                try await conversation.unpauseTask(id: id)
            case .cancelTask(let id):
                try await conversation.cancelTask(id: id)
            case .cancelReminder(let id):
                try await conversation.cancelReminder(id: id)
            }
            return true
        } catch {
            await publish(
                .reply(
                    .failed(
                        conversationID: conversationID,
                        turnID: nil,
                        message: String(describing: error)
                    )
                )
            )
            return false
        }
    }

    private func publish(_ event: OutboundEvent) async {
        try? await conversationConnection.broadcast(event)
    }

    private func resolveConversation(
        _ conversationID: ConversationID,
        agentRole: String
    ) async throws -> Conversation {
        try await Conversation.resolve(
            on: actorSystem,
            conversationID: conversationID,
            agentDirectoryID: "agent-directory",
            agentRole: agentRole,
            memoryExtraction: await agentProfiles.memoryExtractionConfiguration(
                forProfileID: agentRole
            )
        )
    }

    /// The channel actor is the routing authority for channel sessions. Web
    /// sessions use the configured application default.
    private func resolvedAgentRole(for conversationID: ConversationID) async throws -> String {
        if case .channel(let channelID) = source {
            let expectedChannelID = ChannelID(
                provider: TelegramProvider.providerID,
                instanceID: channelID.uuidString
            )
            guard conversationID.channel == expectedChannelID else {
                throw LiveSessionRoutingError.channelIdentityMismatch
            }

            let channel = try await TelegramChannel.resolve(
                on: actorSystem,
                channelID: channelID
            )
            guard case .active(let configuration, _) = try await channel.currentState(),
                configuration.enabled
            else {
                throw LiveSessionRoutingError.channelUnavailable
            }

            let agentRouting = configuration.agentRouting
            switch agentRouting {
            case .defaultProfile:
                return try await agentProfiles.defaultProfileID()
            case .profile(let binding):
                guard let profile = await agentProfiles.profile(id: binding),
                    profile.availability == .enabled
                else {
                    throw LiveSessionRoutingError.unavailableProfile(binding)
                }
                return profile.id
            }
        }
        return try await agentProfiles.defaultProfileID()
    }

    private func attach(
        to conversation: Conversation,
        conversationID: ConversationID
    ) async throws {
        guard conversations[conversationID] == nil else { return }
        try await conversation.addConnection(conversationConnection)
        conversations[conversationID] = conversation
    }
}
