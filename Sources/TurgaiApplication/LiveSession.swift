import AsyncAlgorithms
import DistributedCluster
import EventSourcing
import Hail
import ServiceLifecycle
import TurgaiConversations
import TurgaiDomain
import TurgaiHail
import TurgaiMemory
import TurgaiPeople
import TurgaiSpaces

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

/// Where a live session comes from: an app's connection, for whoever reads in it, or a chat of
/// one of a space's connections, whose conversations are all on its channel.
public enum LiveSessionSource: Sendable, Equatable {
    case web
    case chat(on: ChannelID)
}

private enum LiveSessionRoutingError: Error {
    case channelIdentityMismatch
    /// An app's session opened a conversation for no one.
    case noReader
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

public actor LiveSession {
    /// Unbounded delivery buffer. Unlike `AsyncChannel` (a rendezvous that
    /// suspends `send` until a consumer iterates), yielding into this stream
    /// never waits: a slow or dead client can only fill its own buffer, and
    /// the only backpressure left in the system lives in the route's socket
    /// writer, where it belongs.
    public typealias OutputStream = AsyncStream<OutboundDelivery>

    public let id: String
    public nonisolated let output: OutputStream
    /// What's said in it, as its owner gives it: it runs until this finishes.
    public nonisolated let input: AsyncChannel<ConversationInputDelivery>

    private let actorSystem: ClusterSystem
    private let outputContinuation: OutputStream.Continuation
    /// Who's the same human as whom, which `/link` says.
    private let linking: PersonLinking
    private let source: LiveSessionSource
    private let conversationConnection: ConversationConnection
    private let deliveryRegistry: OutboundDeliveryRegistry
    /// The conversations it's shown, each with the space it's one of.
    private var conversations: [ConversationID: SpaceID] = [:]
    private var finished = false

    public init(
        id: String,
        actorSystem: ClusterSystem,
        input: AsyncChannel<ConversationInputDelivery> = AsyncChannel(),
        linking: PersonLinking,
        source: LiveSessionSource
    ) {
        self.id = id
        self.actorSystem = actorSystem
        self.input = input
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
                // A reply or a notice is taken only once it's sent: until then the conversation
                // keeps it, and a notice's workflow tries again. What a turn shows meanwhile isn't
                // waited for.
                defer { await deliveryRegistry.remove(delivery) }
                if event.mustArrive { try await delivery.wait() }
            }
        )
    }

    /// Handles what's said in it until its input finishes, or its task is cancelled; then it's
    /// finished.
    public func run() async {
        defer { await finish() }
        for await delivery in input {
            if Task.isCancelled {
                await delivery.receipt.cancel()
                return
            }
            if await handle(delivery.input, in: delivery.space) {
                await delivery.receipt.acknowledge()
            } else {
                await delivery.receipt.reject()
            }
        }
    }

    private func finish() async {
        guard !self.finished else { return }
        self.finished = true
        // Unblock the output consumer and fail any deliveries Telegram's
        // pipeline still considers in flight.
        self.outputContinuation.finish()
        await self.deliveryRegistry.failAll()
        for (conversation, space) in self.conversations {
            try? await Space.identified(by: space, on: actorSystem).close(conversation, to: conversationConnection)
        }
        self.conversations.removeAll()
    }

    private func handle(_ input: ConversationInput, in spaceID: SpaceID) async -> Bool {
        switch input {
        case .connect(let conversationID, let person):
            do {
                try await attach(to: conversationID, in: spaceID, for: person)
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

        case .connectChat(let conversationID):
            guard case .chat = source else { return false }
            do {
                try await attach(to: conversationID, in: spaceID, for: nil)
                return true
            } catch {
                actorSystem.log.error(
                    "Could not connect a chat's conversation",
                    metadata: ["conversationID": .string(conversationID.stableKey), "error": "\(error)"])
                return false
            }

        case .detach(let conversationID):
            guard let space = conversations.removeValue(forKey: conversationID) else { return true }
            try? await Space.identified(by: space, on: actorSystem).close(conversationID, to: conversationConnection)
            return true

        case .message(let message, let turnID):
            actorSystem.log.debug(
                "Message for conversation",
                metadata: ["conversation": "\(message.conversationID.stableKey)", "turn": "\(turnID.rawValue)"])
            do {
                let space = try await space(spaceID, for: message.conversationID)
                try await followIfTheChatSays(message.userID, in: message.conversationID, of: space)
                try await attach(to: message.conversationID, in: spaceID, for: message.userID)
                for case .person(let person) in message.to {
                    try await bringIn(person, mentionedBy: message.userID, to: message.conversationID, of: space)
                }
                try await space.say(message, turnID: turnID)
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
                let space = try await space(spaceID, for: conversationID)
                try await followIfTheChatSays(person, in: conversationID, of: space)
                try await attach(to: conversationID, in: spaceID, for: person)
                try await space.reset(conversationID, by: person)
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

        case .stop(let conversationID, let person):
            // The session's own conversation, as it's attached to it: its space decides who may.
            do {
                try await space(spaceID, for: conversationID).stop(conversationID, by: person)
                return true
            } catch {
                await publish(
                    .reply(.failed(conversationID: conversationID, turnID: nil, message: String(describing: error))))
                return false
            }

        case .answer(let conversationID, let id, let answer, let person):
            // Only a conversation this session is attached to hears its answer; its space decides
            // whose answer counts.
            guard let space = conversations[conversationID] else { return false }
            do {
                try await Space.identified(by: space, on: actorSystem).answer(
                    id, answer, by: person, in: conversationID)
                return true
            } catch {
                return false
            }

        case .memory(let conversationID, _, let userID):
            return await handleUserCommand(.memory, conversationID: conversationID, in: spaceID, userID: userID)
        case .forget(let conversationID, _, let userID):
            return await handleUserCommand(.forget, conversationID: conversationID, in: spaceID, userID: userID)
        case .context(let conversationID, _, let userID):
            return await handleUserCommand(.context, conversationID: conversationID, in: spaceID, userID: userID)
        case .diagnose(let conversationID, _, let userID):
            return await handleUserCommand(.diagnose, conversationID: conversationID, in: spaceID, userID: userID)

        case .command(let command):
            switch command {
            case .link(let ask, let conversationID, _, let userID):
                return await link(ask, by: userID, in: conversationID, of: spaceID)
            case .reminders(let conversationID, _, let userID):
                return await handleUserCommand(.reminders, conversationID: conversationID, in: spaceID, userID: userID)
            case .tasks(let conversationID, _, let userID):
                return await handleUserCommand(.tasks, conversationID: conversationID, in: spaceID, userID: userID)
            case .pauseTask(let id, let conversationID, _, let userID):
                return await handleUserCommand(
                    .pauseTask(id), conversationID: conversationID, in: spaceID, userID: userID)
            case .unpauseTask(let id, let conversationID, _, let userID):
                return await handleUserCommand(
                    .unpauseTask(id), conversationID: conversationID, in: spaceID, userID: userID)
            case .cancelTask(let id, let conversationID, _, let userID):
                return await handleUserCommand(
                    .cancelTask(id), conversationID: conversationID, in: spaceID, userID: userID)
            case .cancelReminder(let id, let conversationID, _, let userID):
                return await handleUserCommand(
                    .cancelReminder(id), conversationID: conversationID, in: spaceID, userID: userID)
            case .objects(let conversationID, _, let userID):
                return await handleUserCommand(.objects, conversationID: conversationID, in: spaceID, userID: userID)
            case .object(let id, let conversationID, _, let userID):
                return await handleUserCommand(.object(id), conversationID: conversationID, in: spaceID, userID: userID)
            case .forgetFact(let id, let conversationID, _, let userID):
                return await handleUserCommand(
                    .forgetFact(id), conversationID: conversationID, in: spaceID, userID: userID)
            case .memoryOn(let conversationID, _, let userID):
                return await handleUserCommand(
                    .remembering(.on), conversationID: conversationID, in: spaceID, userID: userID)
            case .memoryOff(let conversationID, _, let userID):
                return await handleUserCommand(
                    .remembering(.off), conversationID: conversationID, in: spaceID, userID: userID)
            }
        }
    }

    /// `/link`, asked in the conversation `conversationID` of `space` by `person`: answered there.
    private func link(
        _ ask: LinkAsk, by person: TurgaiDomain.UserID, in conversationID: ConversationID, of spaceID: SpaceID
    ) async -> Bool {
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
            let space = try await space(spaceID, for: conversationID)
            try await attach(to: conversationID, in: spaceID, for: person)
            try await space.notify(conversationID, reply)
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
        in spaceID: SpaceID,
        userID: TurgaiDomain.UserID
    ) async -> Bool {
        do {
            let space = try await space(spaceID, for: conversationID)
            try await followIfTheChatSays(userID, in: conversationID, of: space)
            try await attach(to: conversationID, in: spaceID, for: userID)
            let commands = ChatCommands(space: space, conversation: conversationID, person: userID, system: actorSystem)
            switch command {
            case .memory: try await space.showMemory(in: conversationID, for: userID)
            case .forget: try await space.forgetMemory(in: conversationID, for: userID)
            case .context: try await space.showContext(in: conversationID, for: userID)
            case .diagnose: try await space.showDiagnostics(in: conversationID, for: userID)
            case .reminders: try await commands.reminders()
            case .tasks: try await commands.tasks()
            case .pauseTask(let name): try await commands.change(.pause, named: name)
            case .unpauseTask(let name): try await commands.change(.resume, named: name)
            case .cancelTask(let name): try await commands.change(.cancel, named: name)
            case .cancelReminder(let name): try await commands.cancelReminder(named: name)
            case .objects: try await commands.objects()
            case .object(let id): try await commands.object(id)
            case .forgetFact(let id): try await space.forgetFact(id, in: conversationID, for: userID)
            case .remembering(let remembering):
                try await space.setRemembering(remembering, in: conversationID, for: userID)
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

    /// The space `id`, whose conversation `conversationID` is: a channel session answers only its
    /// own channel's chats.
    private func space(_ id: SpaceID, for conversationID: ConversationID) async throws -> Space {
        if case .chat(let channel) = source, conversationID.channel != channel {
            throw LiveSessionRoutingError.channelIdentityMismatch
        }
        return try await Space.identified(by: id, on: actorSystem)
    }

    /// `person` one of the conversation's people when its chat says so: anyone writing in a
    /// channel's chat is, and in its space, where it started the first time. In Turgai's apps, no
    /// one is let in by writing.
    private func followIfTheChatSays(
        _ person: TurgaiDomain.UserID, in conversationID: ConversationID, of space: Space
    ) async throws {
        guard case .chat = source else { return }
        try await space.followChat(conversationID, by: person)
    }

    /// `person`, whom `mentioner` says something to, in the conversation too: as the chat's platform
    /// says, or, in Turgai's apps, added by whoever mentions them, as anyone in it may add someone
    /// from its space.
    private func bringIn(
        _ person: TurgaiDomain.UserID, mentionedBy mentioner: TurgaiDomain.UserID,
        to conversationID: ConversationID, of space: Space
    ) async throws {
        switch source {
        case .chat: try await space.admitToChat(person, in: conversationID)
        case .web: try await space.add(.person(person), to: conversationID, by: mentioner)
        }
    }

    /// It shown what happens in the conversation `conversationID` of `spaceID` from now on: a
    /// chat's session for everyone in the chat, an app's for `reader`, who reads it there.
    private func attach(
        to conversationID: ConversationID, in spaceID: SpaceID, for reader: TurgaiDomain.UserID?
    ) async throws {
        guard conversations[conversationID] == nil else { return }
        let space = try await space(spaceID, for: conversationID)
        switch (source, reader) {
        case (.chat, _): try await space.openChat(conversationID, to: conversationConnection)
        case (.web, let reader?): try await space.open(conversationID, to: conversationConnection, for: reader)
        case (.web, nil): throw LiveSessionRoutingError.noReader
        }
        conversations[conversationID] = spaceID
    }
}

extension OutboundEvent {
    /// Whether it must reach whoever's on the other side, not only be shown while it's live: a
    /// reply its conversation keeps until it's taken, or a notice whose workflow tries again.
    var mustArrive: Bool {
        switch self {
        case .reply(.finished), .notice, .noticeWithActions: true
        case .reply, .reset, .asked, .answered, .noted, .unnoted: false
        }
    }
}
