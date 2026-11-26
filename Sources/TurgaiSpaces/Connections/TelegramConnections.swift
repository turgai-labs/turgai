import AsyncAlgorithms
import DistributedCluster
import Hail
import Logging
import ServiceLifecycle
import TurgaiConversations
import TurgaiDomain
import TurgaiHail
import TurgaiPeople
import TurgaiTelegram

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// Pure delivery policy for one Telegram connection.
///
/// The input stream is intentionally bounded by the bridge. This reducer
/// keeps the replaceable preview as a value, while reliable events stay in a
/// FIFO queue until their transport effect completes.
enum TelegramDelivery {
    typealias TurnID = TurgaiDomain.TurnID

    enum Input: Sendable {
        case preview(Preview)
        case terminal(OutboundDelivery)
        case required(OutboundDelivery)
    }

    struct Preview: Sendable {
        let event: OutboundEvent
        let turnID: TurnID
    }

    struct State: Sendable {
        enum PreviewStatus: Sendable {
            case idle
            case sending(Preview)
            case waiting(Preview, until: ContinuousClock.Instant)

            var isSending: Bool {
                if case .sending = self { return true }
                return false
            }

            var isIdle: Bool {
                if case .idle = self { return true }
                return false
            }

            var turnID: TurnID? {
                switch self {
                case .idle:
                    nil
                case .sending(let preview), .waiting(let preview, _):
                    preview.turnID
                }
            }
        }

        var pendingPreview: Preview? = nil
        var pendingReliable: [OutboundDelivery] = []
        var previewStatus: PreviewStatus = .idle
        var reliableInFlight: OutboundDelivery?
        var nextPreviewAt: ContinuousClock.Instant?
        var rateLimitRetries = 0
        var terminalizedTurns: Set<TurnID> = []
        var inputFinished = false

        var isQuiescent: Bool {
            pendingPreview == nil
                && pendingReliable.isEmpty
                && previewStatus.isIdle
                && reliableInFlight == nil
        }

        var isFinished: Bool {
            inputFinished && isQuiescent
        }
    }

    enum Action: Sendable {
        case previewReceived(Preview, at: ContinuousClock.Instant)
        case terminalReceived(
            OutboundDelivery,
            turnID: TurnID?,
            at: ContinuousClock.Instant
        )
        case requiredReceived(OutboundDelivery, at: ContinuousClock.Instant)
        case previewSent(at: ContinuousClock.Instant)
        case previewRateLimited(until: ContinuousClock.Instant, at: ContinuousClock.Instant)
        case previewFailed(at: ContinuousClock.Instant)
        case reliableSent(at: ContinuousClock.Instant)
        case reliableFailed(at: ContinuousClock.Instant)
        case waitFinished(at: ContinuousClock.Instant)
        case inputFinished(at: ContinuousClock.Instant)
    }

    enum Effect: Sendable {
        case none
        case sendPreview(Preview)
        case sendReliable(OutboundDelivery)
        case wait(until: ContinuousClock.Instant)
    }

    static func reduce(
        _ state: inout State,
        _ action: Action,
        configuration: TelegramDeliveryConfiguration
    ) -> Effect {
        switch action {
        case .previewReceived(let preview, let at):
            guard !state.terminalizedTurns.contains(preview.turnID) else {
                return .none
            }
            state.pendingPreview = preview
            return startNext(&state, now: at, configuration: configuration)

        case .terminalReceived(let delivery, let turnID, let at):
            if let turnID {
                if state.pendingPreview?.turnID == turnID {
                    state.pendingPreview = nil
                }
                if state.previewStatus.turnID == turnID {
                    state.terminalizedTurns.insert(turnID)
                }
            }
            state.pendingReliable.append(delivery)
            return startNext(&state, now: at, configuration: configuration)

        case .requiredReceived(let delivery, let at):
            state.pendingReliable.append(delivery)
            return startNext(&state, now: at, configuration: configuration)

        case .previewSent(let at):
            guard case .sending(let preview) = state.previewStatus else {
                return .none
            }
            state.previewStatus = .idle
            state.terminalizedTurns.remove(preview.turnID)
            state.rateLimitRetries = 0
            state.nextPreviewAt = at.advanced(
                by: configuration.minimumDraftInterval
            )
            return startNext(&state, now: at, configuration: configuration)

        case .previewRateLimited(let until, let at):
            guard case .sending(let preview) = state.previewStatus else {
                return .none
            }

            switch state.nextPreviewAt {
            case let current? where current < until:
                state.nextPreviewAt = until
            case nil:
                state.nextPreviewAt = until
            default:
                break
            }

            if state.terminalizedTurns.contains(preview.turnID) {
                state.previewStatus = .idle
                state.terminalizedTurns.remove(preview.turnID)
                state.rateLimitRetries = 0
                return startNext(&state, now: at, configuration: configuration)
            }

            if state.rateLimitRetries >= configuration.maximumRateLimitRetries {
                state.previewStatus = .idle
                state.rateLimitRetries = 0
                return startNext(&state, now: at, configuration: configuration)
            }

            if state.pendingPreview == nil {
                state.pendingPreview = preview
            }
            state.rateLimitRetries += 1
            state.previewStatus = .waiting(preview, until: until)
            return .wait(until: until)

        case .previewFailed(let at):
            guard case .sending(let preview) = state.previewStatus else {
                return .none
            }
            state.previewStatus = .idle
            state.terminalizedTurns.remove(preview.turnID)
            state.rateLimitRetries = 0
            return startNext(&state, now: at, configuration: configuration)

        case .reliableSent(let at), .reliableFailed(let at):
            state.reliableInFlight = nil
            return startNext(&state, now: at, configuration: configuration)

        case .waitFinished(let at):
            guard case .waiting(let preview, _) = state.previewStatus else {
                return .none
            }
            state.previewStatus = .idle
            if state.terminalizedTurns.remove(preview.turnID) != nil {
                state.rateLimitRetries = 0
                if state.pendingPreview?.turnID == preview.turnID {
                    state.pendingPreview = nil
                }
            }
            return startNext(&state, now: at, configuration: configuration)

        case .inputFinished(let at):
            state.inputFinished = true
            return startNext(&state, now: at, configuration: configuration)
        }
    }

    private static func startNext(
        _ state: inout State,
        now: ContinuousClock.Instant,
        configuration: TelegramDeliveryConfiguration
    ) -> Effect {
        if state.reliableInFlight == nil,
            !state.pendingReliable.isEmpty,
            !state.previewStatus.isSending
        {
            let delivery = state.pendingReliable.removeFirst()
            state.reliableInFlight = delivery
            return .sendReliable(delivery)
        }

        guard state.reliableInFlight == nil,
            state.previewStatus.isIdle,
            let preview = state.pendingPreview
        else {
            return .none
        }

        guard !state.terminalizedTurns.contains(preview.turnID) else {
            state.pendingPreview = nil
            return .none
        }

        if let nextPreviewAt = state.nextPreviewAt, now < nextPreviewAt {
            state.previewStatus = .waiting(preview, until: nextPreviewAt)
            return .wait(until: nextPreviewAt)
        }

        state.pendingPreview = nil
        state.previewStatus = .sending(preview)
        return .sendPreview(preview)
    }

    static func turnID(of event: OutboundEvent) -> TurnID? {
        switch event {
        case .reply(let reply):
            switch reply {
            case .userMessage(_, let turnID, _, _, _, _, _):
                turnID
            case .started(_, let turnID),
                .phase(_, let turnID, _),
                .status(_, let turnID, _),
                .step(_, let turnID, _),
                .partial(_, let turnID, _),
                .keepAlive(_, let turnID, _),
                .finished(_, let turnID, _, _),
                .completed(_, let turnID):
                turnID
            case .failed(_, let turnID, _):
                turnID
            }
        case .notice(_, let turnID, _):
            turnID
        case .noticeWithActions(_, let turnID, _, _):
            turnID
        case .reset, .asked, .answered, .noted, .unnoted:
            nil
        }
    }
}

/// A space's Telegram connection: its bot, polling from where it read last, each chat a session
/// into the space.
public enum TelegramConnections {
    /// Runs `connection`, one of `space`'s, with `access`, until it's cancelled: why it stopped
    /// when it stops by itself.
    public static func run(
        _ connection: Connection, access: TelegramAccess, of space: SpaceID, on system: ClusterSystem,
        serving: @escaping @Sendable (ConnectionRun.Fetch?) async -> Void
    )
        async -> ConnectionStopped
    {
        let logger = system.log
        do {
            guard let runtime = system.installedTurgaiChannelRuntime else {
                return ConnectionStopped("This node runs no connections.")
            }
            let dependencies = try await runtime.dependencies()
            guard let token = try await dependencies.secrets.token(for: connection.id.rawValue) else {
                return ConnectionStopped("It has no bot token.")
            }
            let cursor = try await TelegramCursor.identified(by: connection.id, of: space, on: system)
            // Its chats that were talked in before, so what they do by themselves reaches them.
            let persisted = try await system.singleton
                .proxy(ConversationDirectory.self, name: ConversationDirectory.singletonName)
                .conversations(on: connection.channel)
                .filter { Int64($0.externalAddress.rawValue).map(access.lets) ?? false }
            let running = ChannelBot(
                client: try TelegramAPIClient.live(token: token),
                allowedChatIDs: Set(access.chatIDs),
                initialOffset: try await cursor.offset().next,
                checkpointOffset: { try await cursor.advance(to: $0) },
                into: space,
                channel: connection.channel,
                actorSystem: system,
                linking: dependencies.linking,
                serving: serving,
                logger: logger,
                persistedConversationIDs: persisted
            )
            try await running.run()
            return ConnectionStopped("Its bot stopped.")
        } catch is CancellationError {
            return ConnectionStopped("It was stopped.")
        } catch {
            logger.warning("A Telegram connection stopped", metadata: ["error": "\(error)"])
            return ConnectionStopped(String(describing: error))
        }
    }
}

/// A connection's bot, joined to its space: its ``TelegramBot`` polls and makes one logical
/// Telegram connection per chat, each a live session into the space, whose output is sent back to
/// Telegram.
private actor ChannelBot {
    private let bot: TelegramBot
    private let client: TelegramAPIClient
    private let actorSystem: ClusterSystem
    /// Who's the same human as whom, which `/link` says.
    private let linking: PersonLinking
    /// The channel this bot's chats are in: its connection's.
    private let conversationChannel: ChannelID
    /// Tells its connection's run how its chats' files are got, while it runs.
    private let serving: @Sendable (ConnectionRun.Fetch?) async -> Void
    private let logger: Logger
    private let deliveryConfiguration: TelegramDeliveryConfiguration
    private let persistedConversationIDs: [ConversationID]

    init(
        client: TelegramAPIClient,
        allowedChatIDs: Set<Int64>,
        initialOffset: Int64?,
        checkpointOffset: @escaping @Sendable (Int64) async throws -> Void,
        into space: SpaceID,
        channel conversationChannel: ChannelID,
        actorSystem: ClusterSystem,
        linking: PersonLinking,
        serving: @escaping @Sendable (ConnectionRun.Fetch?) async -> Void,
        logger: Logger,
        delivery: TelegramDeliveryConfiguration = TelegramDeliveryConfiguration(),
        persistedConversationIDs: [ConversationID] = [],
        callbackHandler: @escaping TelegramBot.CallbackHandler = { _ in false }
    ) {
        self.bot = TelegramBot(
            client: client,
            into: space,
            conversationChannel: conversationChannel,
            allowedChatIDs: allowedChatIDs,
            initialOffset: initialOffset,
            checkpointOffset: checkpointOffset,
            configuration: TelegramBotConfiguration(delivery: delivery),
            logger: logger,
            callbackHandler: callbackHandler
        )
        self.client = client
        self.actorSystem = actorSystem
        self.linking = linking
        self.conversationChannel = conversationChannel
        self.serving = serving
        self.logger = logger
        self.deliveryConfiguration = delivery
        self.persistedConversationIDs = persistedConversationIDs
    }

    public func run() async throws {
        // Its chats' attachments are got through it while it runs.
        let client = client
        await serving { attachment in
            let file = try await client.downloadFile(attachment.rawValue)
            return ToolData(body: file.body, contentType: file.contentType)
        }

        let telegramConnections = try await bot.connections()

        do {
            try await withTaskCancellationOrGracefulShutdownHandler(
                operation: {
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        group.addTask {
                            try await self.bot.run()
                        }
                        group.addTask {
                            await self.consume(telegramConnections)
                        }
                        group.addTask {
                            await self.connectPersistedConversations()
                        }

                        defer { group.cancelAll() }
                        try await group.next()
                        try await group.waitForAll()
                    }
                },
                onCancelOrGracefulShutdown: {
                    Task {
                        await self.stop()
                    }
                }
            )
        } catch {
            await serving(nil)
            throw error
        }
        await serving(nil)
    }

    private func consume(
        _ telegramConnections: AsyncStream<TelegramConnection>
    ) async {
        await withDiscardingTaskGroup { group in
            for await connection in telegramConnections {
                group.addTask {
                    await self.bridge(connection)
                }
            }
            group.cancelAll()
        }
    }

    private func bridge(_ connection: TelegramConnection) async {
        let connectionID = await connection.id
        let session = LiveSession(
            id: connectionID, actorSystem: actorSystem, input: await connection.inbound, linking: linking,
            source: .chat(on: conversationChannel))
        // The chat's session runs while its chat does: its output ends as it finishes.
        async let ran: Void = session.run()
        let output = session.output

        let (deliveryStream, deliveryContinuation) =
            AsyncStream<TelegramDelivery.Input>.makeStream(
                bufferingPolicy: .bufferingNewest(1)
            )

        await withDiscardingTaskGroup { group in
            group.addTask { [connection, deliveryStream, logger, deliveryConfiguration] in
                await Self.consumeDeliveries(
                    from: deliveryStream,
                    connection: connection,
                    connectionID: connectionID,
                    logger: logger,
                    configuration: deliveryConfiguration
                )
            }

            for await delivery in output {
                guard !Task.isCancelled else {
                    await delivery.failed("The Telegram connection was cancelled.")
                    break
                }

                switch delivery.event {
                case .reply(.partial):
                    guard let turnID = TelegramDelivery.turnID(of: delivery.event) else {
                        await delivery.failed("The Telegram preview has no turn ID.")
                        continue
                    }
                    let input = TelegramDelivery.Input.preview(
                        TelegramDelivery.Preview(
                            event: delivery.event,
                            turnID: turnID
                        )
                    )
                    switch deliveryContinuation.yield(input) {
                    case .enqueued:
                        await delivery.delivered()
                    case .dropped(let replaced):
                        await delivery.delivered()
                        await Self.failIfReliable(
                            replaced,
                            message: "The Telegram delivery was superseded."
                        )
                    case .terminated:
                        await delivery.failed("The Telegram delivery stream was closed.")
                    @unknown default:
                        await delivery.failed("The Telegram delivery stream was closed.")
                    }

                case .reply(.finished), .reply(.completed), .reply(.failed):
                    await Self.enqueueReliable(
                        .terminal(delivery),
                        continuation: deliveryContinuation
                    )

                default:
                    await Self.enqueueReliable(
                        .required(delivery),
                        continuation: deliveryContinuation
                    )
                }
            }

            deliveryContinuation.finish()
            if Task.isCancelled {
                group.cancelAll()
            }
        }

        await ran
        await bot.remove(connectionID: connectionID)
    }

    private static func consumeDeliveries(
        from stream: AsyncStream<TelegramDelivery.Input>,
        connection: TelegramConnection,
        connectionID: String,
        logger: Logger,
        configuration: TelegramDeliveryConfiguration
    ) async {
        let actions = AsyncChannel<TelegramDelivery.Action>()
        let clock = ContinuousClock()

        await withDiscardingTaskGroup { group in
            group.addTask {
                for await input in stream {
                    let now = clock.now
                    switch input {
                    case .preview(let preview):
                        await actions.send(.previewReceived(preview, at: now))

                    case .terminal(let delivery):
                        await actions.send(
                            .terminalReceived(
                                delivery,
                                turnID: TelegramDelivery.turnID(of: delivery.event),
                                at: now
                            )
                        )

                    case .required(let delivery):
                        await actions.send(.requiredReceived(delivery, at: now))
                    }
                }
                await actions.send(.inputFinished(at: clock.now))
            }

            var state = TelegramDelivery.State()

            for await action in actions {
                let effect = TelegramDelivery.reduce(
                    &state,
                    action,
                    configuration: configuration
                )
                switch effect {
                case .none:
                    break

                case .sendPreview, .sendReliable, .wait:
                    group.addTask {
                        await Self.interpret(
                            effect,
                            connection: connection,
                            connectionID: connectionID,
                            logger: logger,
                            configuration: configuration,
                            clock: clock,
                            actions: actions
                        )
                    }
                }

                if state.isFinished {
                    actions.finish()
                }
            }

            group.cancelAll()
        }
    }

    private static func interpret(
        _ effect: TelegramDelivery.Effect,
        connection: TelegramConnection,
        connectionID: String,
        logger: Logger,
        configuration: TelegramDeliveryConfiguration,
        clock: ContinuousClock,
        actions: AsyncChannel<TelegramDelivery.Action>
    ) async {
        do {
            switch effect {
            case .none:
                return

            case .sendPreview(let preview):
                try await connection.send(preview.event)
                await actions.send(.previewSent(at: clock.now))

            case .sendReliable(let delivery):
                try await connection.send(delivery.event)
                await delivery.delivered()
                await actions.send(.reliableSent(at: clock.now))

            case .wait(let until):
                try await clock.sleep(until: until)
                await actions.send(.waitFinished(at: clock.now))
            }
        } catch is CancellationError {
            switch effect {
            case .sendPreview:
                await actions.send(.previewFailed(at: clock.now))
            case .sendReliable(let delivery):
                await delivery.failed("The Telegram delivery was cancelled.")
                await actions.send(.reliableFailed(at: clock.now))
            case .wait, .none:
                break
            }
        } catch let error as TelegramAPIError {
            switch effect {
            case .sendPreview:
                if case .rateLimited(let retryAfter) = error {
                    let now = clock.now
                    let delay = retryAfter ?? configuration.fallbackRateLimitDelay
                    logger.warning(
                        "Telegram preview rate limited on connection \(connectionID); retrying in \(delay)"
                    )
                    await actions.send(
                        .previewRateLimited(
                            until: now.advanced(by: delay),
                            at: now
                        )
                    )
                } else {
                    await actions.send(.previewFailed(at: clock.now))
                    logger.warning(
                        "Telegram preview delivery failed on connection \(connectionID): \(error)"
                    )
                }

            case .sendReliable(let delivery):
                await delivery.failed(String(describing: error))
                await actions.send(.reliableFailed(at: clock.now))
                logger.warning(
                    "Telegram delivery failed on connection \(connectionID): \(error)"
                )

            case .wait, .none:
                break
            }
        } catch {
            switch effect {
            case .sendPreview:
                await actions.send(.previewFailed(at: clock.now))
                logger.warning(
                    "Telegram preview delivery failed on connection \(connectionID): \(error)"
                )

            case .sendReliable(let delivery):
                await delivery.failed(String(describing: error))
                await actions.send(.reliableFailed(at: clock.now))
                logger.warning(
                    "Telegram delivery failed on connection \(connectionID): \(error)"
                )

            case .wait, .none:
                break
            }
        }
    }

    private static func enqueueReliable(
        _ input: TelegramDelivery.Input,
        continuation: AsyncStream<TelegramDelivery.Input>.Continuation
    ) async {
        let delivery: OutboundDelivery
        switch input {
        case .preview:
            return
        case .terminal(let value), .required(let value):
            delivery = value
        }

        switch continuation.yield(input) {
        case .enqueued:
            try? await delivery.wait()
        case .dropped(let replaced):
            await failIfReliable(
                replaced,
                message: "The reliable Telegram delivery was superseded."
            )
            try? await delivery.wait()
        case .terminated:
            await delivery.failed("The Telegram delivery stream was closed.")
        @unknown default:
            await delivery.failed("The Telegram delivery stream was closed.")
        }
    }

    private static func failIfReliable(
        _ input: TelegramDelivery.Input,
        message: String
    ) async {
        switch input {
        case .preview:
            break
        case .terminal(let delivery), .required(let delivery):
            await delivery.failed(message)
        }
    }

    private func stop() async {
        await bot.stop()
    }

    private func connectPersistedConversations() async {
        guard !persistedConversationIDs.isEmpty else { return }

        logger.info(
            "Connecting persisted conversations",
            metadata: ["count": .string(String(persistedConversationIDs.count))]
        )

        for conversationID in persistedConversationIDs {
            let connected = await bot.connect(
                conversationID: conversationID
            )
            if !connected {
                logger.warning(
                    "Could not connect persisted conversation",
                    metadata: [
                        "conversationID": .string(conversationID.stableKey)
                    ]
                )
            }
        }
    }
}
