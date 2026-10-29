import AsyncAlgorithms
import DistributedCluster
import Hail
import Logging
import ServiceLifecycle
import TurgaiDomain
import TurgaiHail
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
            case .userMessage(_, let turnID, _, _):
                turnID
            case .started(_, let turnID),
                .phase(_, let turnID, _),
                .status(_, let turnID, _),
                .step(_, let turnID, _),
                .partial(_, let turnID, _),
                .keepAlive(_, let turnID, _),
                .finished(_, let turnID, _),
                .completed(_, let turnID):
                turnID
            case .failed(_, let turnID, _):
                turnID
            }
        case .notice(_, let turnID, _):
            turnID
        case .noticeWithActions(_, let turnID, _, _):
            turnID
        case .reset, .asked, .answered:
            nil
        }
    }
}

/// The node's Telegram: every channel's bot, each run while its channel is enabled. Every round it
/// asks each channel what its bot runs as, a message that activates the channel, so a changed,
/// disabled or deleted channel's bot is run again or stopped, and a new channel's started.
public actor TelegramService: Service {
    /// What a channel's bot runs as: a change to either runs it again.
    struct Bot: Equatable, Sendable {
        let configuration: ChannelConfiguration<TelegramProvider>
        let token: String
    }

    private let actorSystem: ClusterSystem
    private let dependencies: TurgaiChannelRuntimeDependencies
    private let discoverChannelIDs: @Sendable () async throws -> [UUID]
    private let logger: Logger
    /// How often each channel is asked again, and the channels looked for.
    private let round: Duration

    public init(
        actorSystem: ClusterSystem,
        dependencies: TurgaiChannelRuntimeDependencies,
        discoverChannelIDs: @escaping @Sendable () async throws -> [UUID],
        round: Duration = .seconds(30)
    ) {
        self.actorSystem = actorSystem
        self.dependencies = dependencies
        self.discoverChannelIDs = discoverChannelIDs
        self.logger = actorSystem.log
        self.round = round
    }

    public func run() async {
        _ = try? await cancelWhenGracefulShutdown {
            await withDiscardingTaskGroup { group in
                var running: Set<UUID> = []
                while !Task.isCancelled {
                    do {
                        for channelID in try await self.discoverChannelIDs() where running.insert(channelID).inserted {
                            group.addTask { await self.keepRunning(channelID) }
                        }
                    } catch {
                        self.logger.warning(
                            "Could not list the Telegram channels", metadata: ["error": "\(error)"])
                    }
                    try? await Task.sleep(for: self.round)
                }
                group.cancelAll()
            }
        }
    }

    /// Runs the channel's bot while it's enabled, and again whenever what it runs as changes.
    private func keepRunning(_ channelID: UUID) async {
        let channel: Logger.MetadataValue = "\(channelID.uuidString)"
        while !Task.isCancelled {
            guard let bot = await runnable(channelID) else {
                try? await Task.sleep(for: round)
                continue
            }
            logger.info("Telegram channel running", metadata: ["channel": channel])
            let stoppedByItself = await withTaskGroup(of: Bool.self) { group in
                group.addTask {
                    await self.run(bot)
                    return true
                }
                // Each round, the channel again: when its bot runs as something else, this one stops.
                group.addTask {
                    while !Task.isCancelled {
                        try? await Task.sleep(for: self.round)
                        if await self.runnable(channelID) != bot { break }
                    }
                    return false
                }
                let first = await group.next() ?? false
                group.cancelAll()
                return first
            }
            logger.info("Telegram channel stopped", metadata: ["channel": channel])
            // One that stopped by itself, such as with a token Telegram refuses, is tried a round later.
            if stoppedByItself { try? await Task.sleep(for: round) }
        }
    }

    /// What the channel's bot runs as now, `nil` when it doesn't run: when it's disabled, deleted,
    /// or has no token.
    private func runnable(_ channelID: UUID) async -> Bot? {
        do {
            let channel = try await TelegramChannel.resolve(on: actorSystem, channelID: channelID)
            guard case .active(let configuration, _) = try await channel.currentState(), configuration.enabled,
                let token = await dependencies.secrets.token(for: channelID)
            else { return nil }
            return Bot(configuration: configuration, token: token)
        } catch {
            logger.warning(
                "Could not read the Telegram channel",
                metadata: ["channel": "\(channelID.uuidString)", "error": "\(error)"])
            return nil
        }
    }

    /// Runs one channel's bot, from the cursor its channel keeps, until it stops or is cancelled.
    private func run(_ bot: Bot) async {
        let channelID = bot.configuration.id
        let allowed = bot.configuration.provider.chatIDs
        let conversationChannel = ChannelID(provider: TelegramProvider.providerID, instanceID: channelID.uuidString)
        do {
            let channel = try await TelegramChannel.resolve(on: actorSystem, channelID: channelID)
            guard case .active(_, let state) = try await channel.currentState() else { return }
            // Its chats that were talked in before, so what they do by themselves reaches them.
            let persisted = try await dependencies.loadPersistedConversationIDs().filter { conversationID in
                guard conversationID.channel == conversationChannel,
                    let chatID = Int64(conversationID.externalAddress.rawValue)
                else { return false }
                return allowed.isEmpty || allowed.contains(chatID)
            }
            let running = ChannelBot(
                client: try TelegramAPIClient.live(token: bot.token),
                allowedChatIDs: Set(allowed),
                initialOffset: state.cursor.offset,
                checkpointOffset: { offset in
                    try await channel.emitProviderEvent(ProviderEvent(.cursorAdvanced(offset)))
                },
                connections: dependencies.connections,
                channelID: channelID,
                files: dependencies.telegramFiles,
                logger: logger,
                persistedConversationIDs: persisted
            )
            try await running.run()
        } catch is CancellationError {
        } catch {
            logger.warning(
                "Telegram channel's bot stopped",
                metadata: ["channel": "\(channelID.uuidString)", "error": "\(error)"])
        }
    }
}

/// One channel's bot, joined to Turgai: its ``TelegramBot`` polls and makes one logical
/// ``TelegramConnection`` per chat, and each is attached to a Turgai live session, whose output
/// is sent back to Telegram.
private actor ChannelBot {
    private let bot: TelegramBot
    private let client: TelegramAPIClient
    private let connections: TurgaiConnections
    private let channelID: UUID
    /// The channel this bot's chats are in.
    private let conversationChannel: ChannelID
    private let files: TelegramFiles
    private let logger: Logger
    private let deliveryConfiguration: TelegramDeliveryConfiguration
    private let persistedConversationIDs: [ConversationID]

    init(
        client: TelegramAPIClient,
        allowedChatIDs: Set<Int64>,
        initialOffset: Int64?,
        checkpointOffset: @escaping @Sendable (Int64) async throws -> Void,
        connections: TurgaiConnections,
        channelID: UUID,
        files: TelegramFiles,
        logger: Logger,
        delivery: TelegramDeliveryConfiguration = TelegramDeliveryConfiguration(),
        persistedConversationIDs: [ConversationID] = [],
        callbackHandler: @escaping TelegramBot.CallbackHandler = { _ in false }
    ) {
        let conversationChannel = ChannelID(provider: "telegram", instanceID: channelID.uuidString)
        self.bot = TelegramBot(
            client: client,
            conversationChannel: conversationChannel,
            allowedChatIDs: allowedChatIDs,
            initialOffset: initialOffset,
            checkpointOffset: checkpointOffset,
            configuration: TelegramBotConfiguration(delivery: delivery),
            logger: logger,
            callbackHandler: callbackHandler
        )
        self.client = client
        self.connections = connections
        self.channelID = channelID
        self.conversationChannel = conversationChannel
        self.files = files
        self.logger = logger
        self.deliveryConfiguration = delivery
        self.persistedConversationIDs = persistedConversationIDs
    }

    public func run() async throws {
        // Its chats' attachments are got through it while it runs.
        await files.register(conversationChannel, client.downloadFile)

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
            await files.unregister(conversationChannel)
            throw error
        }
        await files.unregister(conversationChannel)
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
        let inbound = await connection.inbound
        let session = await connections.addLiveSession(
            id: connectionID,
            source: .channel(channelID),
            inbound: inbound
        )
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

        await connections.finishLiveSession(id: connectionID, handle: session.handle)
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
