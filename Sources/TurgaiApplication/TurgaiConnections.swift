import AsyncAlgorithms
import DistributedCluster
import Hail
import ServiceLifecycle
import TurgaiDomain
import TurgaiMemory
import TurgaiPeople

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
    }

    public struct WebSession: Sendable {
        public let input: AsyncChannel<ConversationInputDelivery>
        public let output: AsyncStream<OutboundDelivery>
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
    private let conversations: ConversationStorage
    private let linking: PersonLinking
    private let connectionStream: AsyncStream<Connection>
    private let connectionContinuation: AsyncStream<Connection>.Continuation
    private let outboundConnections = OutboundConnections()

    public init(
        actorSystem: ClusterSystem,
        agentProfiles: TurgaiAgentProfileStore,
        conversations: ConversationStorage,
        linking: PersonLinking
    ) {
        self.actorSystem = actorSystem
        self.agentProfiles = agentProfiles
        self.conversations = conversations
        self.linking = linking
        (self.connectionStream, self.connectionContinuation) =
            AsyncStream<Connection>.makeStream()
    }

    /// The agent that answers `conversationID`: as its Telegram bot's channel routes its chats, or,
    /// for any other chat, the default profile.
    static func agentRole(
        for conversationID: ConversationID, agentProfiles: TurgaiAgentProfileStore, on actorSystem: ClusterSystem
    ) async throws -> String {
        guard conversationID.channel.providerName == TelegramProvider.providerID,
            let channelID = UUID(uuidString: conversationID.channel.instanceID)
        else { return try await agentProfiles.defaultProfileID() }
        let channel = try await TelegramChannel.resolve(on: actorSystem, channelID: channelID)
        guard case .active(let configuration, _) = try await channel.currentState(), configuration.enabled else {
            throw LiveSessionRoutingError.channelUnavailable
        }
        switch configuration.agentRouting {
        case .defaultProfile:
            return try await agentProfiles.defaultProfileID()
        case .profile(let binding):
            guard let profile = try await agentProfiles.profile(id: binding), profile.availability == .enabled else {
                throw LiveSessionRoutingError.unavailableProfile(binding)
            }
            return profile.id
        }
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
            conversations: conversations,
            linking: linking,
            source: source
        )
        actorSystem.log.debug("Live session added", metadata: ["session": "\(id)"])
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

    /// What's been said in a conversation, as `person` reads it: refused unless they're in it.
    public func history(
        of conversationID: ConversationID, for person: TurgaiDomain.UserID
    ) async throws -> [ConversationHistoryEntry] {
        try await Conversation.resolve(on: actorSystem, conversationID: conversationID).history(for: person)
    }

    /// The agent's past turns in a conversation, step by step, as `person` asks for them.
    public func turns(
        of conversationID: ConversationID, askedBy person: TurgaiDomain.UserID
    ) async throws -> [ConversationTurn] {
        try await Conversation.resolve(on: actorSystem, conversationID: conversationID).turns(askedBy: person)
    }

    /// Whether a conversation's agent is answering, as `person` sees it: refused unless they're in it.
    public func status(
        of conversationID: ConversationID, for person: TurgaiDomain.UserID
    ) async throws -> ConversationStatus {
        try await Conversation.resolve(on: actorSystem, conversationID: conversationID).status(for: person)
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
    case objects
    case object(String)
    case forgetFact(String)
    case remembering(Remembering)
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
    /// The conversations there are, which a conversation joins with its first message.
    private let conversationStorage: ConversationStorage
    /// Who's the same human as whom, which `/link` says.
    private let linking: PersonLinking
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
        conversations: ConversationStorage,
        linking: PersonLinking,
        source: LiveSessionSource
    ) {
        self.id = id
        self.actorSystem = actorSystem
        self.inbound = inbound
        self.agentProfiles = agentProfiles
        self.conversationStorage = conversations
        self.linking = linking
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
                let conversation = try await self.resolveConversation(conversationID)
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
            actorSystem.log.debug(
                "Message for conversation",
                metadata: ["conversation": "\(message.conversationID.stableKey)", "turn": "\(turnID.rawValue)"])
            do {
                let conversation = try await self.resolveConversation(message.conversationID)
                try await self.attach(
                    to: conversation,
                    conversationID: message.conversationID
                )
                try await self.admitIfTheChatSays(message.userID, to: conversation)
                // A conversation is there from its first message.
                try await conversationStorage.add(message.conversationID)
                let memoryExtraction: MemoryExtractionConfiguration? =
                    if let agent = try await conversation.started()?.agent {
                        try await agentProfiles.memoryExtractionConfiguration(forProfileID: agent)
                    } else { nil }
                try await conversation.send(
                    message,
                    turnID: turnID,
                    configuration: Conversation.TurnConfiguration(memoryExtraction: memoryExtraction)
                )
                actorSystem.log.debug(
                    "Message sent to conversation",
                    metadata: ["conversation": "\(message.conversationID.stableKey)", "turn": "\(turnID.rawValue)"])
                return true
            } catch {
                actorSystem.log.warning(
                    "Message didn't reach its conversation",
                    metadata: [
                        "conversation": "\(message.conversationID.stableKey)", "error": "\(error)",
                    ])
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

        case .reset(let conversationID, let person):
            do {
                let conversation = try await resolveConversation(conversationID)
                try await attach(
                    to: conversation,
                    conversationID: conversationID
                )
                try await admitIfTheChatSays(person, to: conversation)
                try await conversation.reset(by: person)
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

        case .chat(let conversationID, let name, let admins, let person):
            do {
                let conversation = try await self.resolveConversation(conversationID)
                let agent = try await TurgaiConnections.agentRole(
                    for: conversationID, agentProfiles: agentProfiles, on: actorSystem)
                try await conversation.followChat(named: name, admins: admins, agent: agent, by: person)
                return true
            } catch {
                actorSystem.log.warning(
                    "A chat's conversation didn't follow it",
                    metadata: ["conversation": "\(conversationID.stableKey)", "error": "\(error)"])
                return false
            }

        case .answer(let conversationID, let id, let answer, let person):
            // Only a conversation this session is attached to hears its answer; its space decides
            // whose answer counts.
            guard let conversation = conversations[conversationID] else { return false }
            do {
                try await conversation.answer(id, answer, by: person)
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
            case .link(let ask, let conversationID, _, let userID):
                return await link(ask, by: userID, in: conversationID)
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
            case .objects(let conversationID, let participantID, let userID):
                return await handleUserCommand(
                    .objects,
                    conversationID: conversationID,
                    participantID: participantID,
                    userID: userID
                )
            case .object(let id, let conversationID, let participantID, let userID):
                return await handleUserCommand(
                    .object(id),
                    conversationID: conversationID,
                    participantID: participantID,
                    userID: userID
                )
            case .forgetFact(let id, let conversationID, let participantID, let userID):
                return await handleUserCommand(
                    .forgetFact(id), conversationID: conversationID, participantID: participantID, userID: userID)
            case .memoryOn(let conversationID, let participantID, let userID):
                return await handleUserCommand(
                    .remembering(.on), conversationID: conversationID, participantID: participantID, userID: userID)
            case .memoryOff(let conversationID, let participantID, let userID):
                return await handleUserCommand(
                    .remembering(.off), conversationID: conversationID, participantID: participantID, userID: userID)
            }
        }
    }

    /// `/link`, asked in `conversationID` by `person`: answered there.
    private func link(_ ask: LinkAsk, by person: TurgaiDomain.UserID, in conversationID: ConversationID) async
        -> Bool
    {
        let reply: String
        do {
            switch ask {
            case .newCode:
                let code = try await linking.code(for: person)
                let minutes = Int(PersonLinking.codeLifetime / 60)
                reply = "Your link code: \(code). Enter it in Turgai on your Mac within \(minutes) minutes."
            case .code(let code):
                reply = "Linked: this is you, as \(Self.said(try await linking.link(person, using: code)))."
            case .notACode:
                reply = PersonLinkingError.codeDoesNotWork.description
            }
        } catch let error as PersonLinkingError {
            reply = error.description
        } catch {
            reply = "Couldn't link: \(error)"
        }
        do {
            let conversation = try await resolveConversation(conversationID)
            try await attach(to: conversation, conversationID: conversationID)
            try await conversation.notify(reply)
            return true
        } catch {
            return false
        }
    }

    /// A linked person, as a reply names them.
    private static func said(_ person: TurgaiDomain.UserID) -> String {
        switch person {
        case .account: "your Turgai account"
        case .telegram(let id): "Telegram user \(id)"
        case .guest: "a guest"
        }
    }

    private func handleUserCommand(
        _ command: UserCommand,
        conversationID: ConversationID,
        participantID: ParticipantID,
        userID: TurgaiDomain.UserID
    ) async -> Bool {
        do {
            let conversation = try await self.resolveConversation(conversationID)
            try await self.attach(
                to: conversation,
                conversationID: conversationID
            )
            try await admitIfTheChatSays(userID, to: conversation)

            switch command {
            case .memory:
                try await conversation.showMemory(for: userID)
            case .forget:
                try await conversation.forgetMemory(for: userID)
            case .context:
                try await conversation.showContext(for: userID)
            case .diagnose:
                try await conversation.showDiagnostics(for: userID)
            case .reminders:
                try await conversation.showReminders(for: userID)
            case .tasks:
                try await conversation.showTasks(for: userID)
            case .pauseTask(let name):
                try await conversation.changeTask(.pause, named: name, by: userID)
            case .unpauseTask(let name):
                try await conversation.changeTask(.resume, named: name, by: userID)
            case .cancelTask(let name):
                try await conversation.changeTask(.cancel, named: name, by: userID)
            case .cancelReminder(let name):
                try await conversation.cancelReminder(named: name, by: userID)
            case .objects:
                try await conversation.showObjects(for: userID)
            case .object(let id):
                try await conversation.showObject(id, for: userID)
            case .forgetFact(let id):
                try await conversation.forgetFact(id, for: userID)
            case .remembering(let remembering):
                try await conversation.setRemembering(remembering, for: userID)
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
        try? await conversationConnection.receive(event)
    }

    /// The conversation `conversationID`: a channel session answers only its own channel's chats.
    private func resolveConversation(_ conversationID: ConversationID) async throws -> Conversation {
        if case .channel(let channelID) = source {
            let expectedChannelID = ChannelID(
                provider: TelegramProvider.providerID,
                instanceID: channelID.uuidString
            )
            guard conversationID.channel == expectedChannelID else {
                throw LiveSessionRoutingError.channelIdentityMismatch
            }
        }
        return try await Conversation.resolve(on: actorSystem, conversationID: conversationID)
    }

    /// `person` one of `conversation`'s people when its chat says so: anyone writing in a channel's
    /// chat is in it. In Turgai's own apps, no one is let in by writing.
    private func admitIfTheChatSays(_ person: TurgaiDomain.UserID, to conversation: Conversation) async throws {
        guard case .channel = source else { return }
        try await conversation.admit(person)
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
