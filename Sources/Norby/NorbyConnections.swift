import AsyncAlgorithms
import DistributedCluster
import Hail
import NorbyApplication
import NorbyDomain
import ServiceLifecycle

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

    func wait() async throws {
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

struct OutboundDelivery: Sendable {
    let id = UUID()
    let event: OutboundEvent
    private let receipt = OutboundDeliveryReceipt()

    init(event: OutboundEvent) {
        self.event = event
    }

    func wait() async throws {
        try await receipt.wait()
    }

    func delivered() async {
        await receipt.delivered()
    }

    func failed(_ message: String) async {
        await receipt.failed(message)
    }
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

/// Owns Norby's live client sessions.
///
/// This follows StagehandConnections: channel services provide an inbound
/// stream to `addLiveSession`, the factory creates a live session, and the
/// returned outbound stream is consumed by that channel service.
public actor NorbyConnections: Service {
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
    }

    private let actorSystem: ClusterSystem
    private let snapshotPolicy: AgentSnapshotPolicy
    private let connectionStream: AsyncStream<Connection>
    private let connectionContinuation: AsyncStream<Connection>.Continuation
    private let outboundConnections = OutboundConnections()

    public init(
        actorSystem: ClusterSystem,
        snapshotPolicy: AgentSnapshotPolicy = .default
    ) {
        self.actorSystem = actorSystem
        self.snapshotPolicy = snapshotPolicy
        (self.connectionStream, self.connectionContinuation) =
            AsyncStream<Connection>.makeStream()
    }

    /// Creates one live Norby session for one external logical connection.
    ///
    /// The caller owns the input stream and receives the output stream. This
    /// is the same factory boundary as StagehandConnections.addLiveSession.
    func addLiveSession(
        id: String,
        inbound: AsyncChannel<ConversationInputDelivery>
    ) async -> LiveSession.OutputStream {
        let session = LiveSession(
            id: id,
            actorSystem: actorSystem,
            inbound: inbound,
            snapshotPolicy: snapshotPolicy
        )
        connectionContinuation.yield(.live(session))
        return session.output
    }

    /// Stops accepting sessions. Existing session workers are cancelled by
    /// the task group and finish their sessions after their input stream ends.
    func stop() {
        connectionContinuation.finish()
    }

    public func run() async throws {
        await withTaskCancellationOrGracefulShutdownHandler(
            operation: {
                await withDiscardingTaskGroup { group in
                    for await connection in self.connectionStream {
                        group.addTask {
                            await self.outboundConnections.add(connection)
                            await self.handleMessages(from: connection)
                            await self.outboundConnections.remove(connection)
                            await connection.finish()
                        }
                    }
                    group.cancelAll()
                }
            },
            onCancelOrGracefulShutdown: {
                self.connectionContinuation.finish()
            }
        )
    }

    private func handleMessages(from connection: Connection) async {
        switch connection {
        case .live(let session):
            await session.run()
        }
    }
}

/// One live Norby session, equivalent to Stagehand's LiveSession.
///
/// It is channel-neutral: Telegram, a web client, or another adapter can
/// feed `ConversationInput` and consume `OutboundEvent` without leaking its
/// transport types into this layer.
private enum UserCommand {
    case memory
    case forget
    case context
    case reminders
    case tasks
    case pauseTask(String)
    case unpauseTask(String)
    case cancelTask(String)
    case cancelReminder(String)
}

actor LiveSession {
    typealias OutputStream = AsyncChannel<OutboundDelivery>

    let id: String
    let handle = UUID()
    let output: OutputStream

    private let actorSystem: ClusterSystem
    private let inbound: AsyncChannel<ConversationInputDelivery>
    private let snapshotPolicy: AgentSnapshotPolicy
    private let conversationConnection: ConversationConnection
    private let deliveryRegistry: OutboundDeliveryRegistry
    private var conversations: [ConversationID: Conversation] = [:]
    private var finished = false

    init(
        id: String,
        actorSystem: ClusterSystem,
        inbound: AsyncChannel<ConversationInputDelivery>,
        snapshotPolicy: AgentSnapshotPolicy
    ) {
        self.id = id
        self.actorSystem = actorSystem
        self.inbound = inbound
        self.snapshotPolicy = snapshotPolicy
        self.output = OutputStream()
        self.deliveryRegistry = OutboundDeliveryRegistry()
        let output = self.output
        let deliveryRegistry = self.deliveryRegistry
        self.conversationConnection = ConversationConnection(
            actorSystem: actorSystem,
            onEvent: { event in
                let delivery = OutboundDelivery(event: event)
                await deliveryRegistry.insert(delivery)
                await output.send(delivery)
                do {
                    try await delivery.wait()
                } catch {
                    await deliveryRegistry.remove(delivery)
                    throw error
                }
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
        guard !finished else { return }
        finished = true
        // Unblock both the output consumer and any Conversation broadcast
        // waiting for Telegram to complete delivery.
        output.finish()
        await deliveryRegistry.failAll()
        for conversation in conversations.values {
            try? await conversation.removeConnection(conversationConnection)
        }
        conversations.removeAll()
    }

    private func handle(_ input: ConversationInput) async -> Bool {
        switch input {
        case .connect(let conversationID):
            do {
                let conversation = try await Conversation.resolve(
                    on: actorSystem,
                    conversationID: conversationID,
                    snapshotPolicy: snapshotPolicy
                )
                try await attach(
                    to: conversation,
                    conversationID: conversationID
                )
                return true
            } catch {
                actorSystem.log.error(
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

                let conversation = try await Conversation.resolve(
                    on: actorSystem,
                    conversationID: message.conversationID,
                    snapshotPolicy: snapshotPolicy
                )
                try await attach(
                    to: conversation,
                    conversationID: message.conversationID
                )
                try await conversation.send(
                    message,
                    turnID: turnID
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
                let conversation = try await Conversation.resolve(
                    on: actorSystem,
                    conversationID: conversationID,
                    snapshotPolicy: snapshotPolicy
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
        userID: NorbyDomain.UserID
    ) async -> Bool {
        do {
            let user = try await User.resolve(on: actorSystem, userID: userID)
            try await user.link(participantID: participantID)

            let conversation = try await Conversation.resolve(
                on: actorSystem,
                conversationID: conversationID,
                snapshotPolicy: snapshotPolicy
            )
            try await attach(
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

    private func attach(
        to conversation: Conversation,
        conversationID: ConversationID
    ) async throws {
        guard conversations[conversationID] == nil else { return }
        try await conversation.addConnection(conversationConnection)
        conversations[conversationID] = conversation
    }
}
