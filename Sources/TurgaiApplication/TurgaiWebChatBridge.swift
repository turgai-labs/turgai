import DistributedCluster
import DurableWorkflows
import Foundation
import Hail
import TurgaiCalls
import TurgaiDomain
import TurgaiMemory
import TurgaiObjects
import TurgaiPeople
import TurgaiSpaces

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
    private struct Runtime {
        let connections: TurgaiConnections
        let objectCatalog: ObjectCatalog
        let channels: ChannelStorage
        let actorSystem: ClusterSystem
        /// Turgai's own space.
        let turgaiSpace: SpaceID
    }

    private var runtime: Runtime?

    public init() {}

    public func install(
        _ connections: TurgaiConnections,
        objectCatalog: ObjectCatalog,
        channels: ChannelStorage,
        actorSystem: ClusterSystem,
        turgaiSpace: SpaceID
    ) {
        self.runtime = Runtime(
            connections: connections,
            objectCatalog: objectCatalog,
            channels: channels,
            actorSystem: actorSystem,
            turgaiSpace: turgaiSpace
        )
    }

    /// Turgai's own space following `accounts`: called Turgai, with each account that can sign in
    /// in it, an administrator as its admin. Before the runtime runs there's no space to tell: it's
    /// told every account as it starts.
    public func follow(_ accounts: [Account]) async throws {
        guard let runtime else { return }
        let inIt = accounts.filter { $0.status != .disabled }.map { account -> (TurgaiDomain.UserID, SpaceRole) in
            (.account(account.id), account.role == .administrator ? .admin : .member)
        }
        try await Space.resolve(on: runtime.actorSystem, id: runtime.turgaiSpace)
            .follow(accounts: Dictionary(uniqueKeysWithValues: inIt), named: Self.turgaisName)
    }

    /// What Turgai's own space is called.
    private static let turgaisName = SpaceName("Turgai")!

    /// `guest` in Turgai's own space, as a member: where their conversations are.
    public func admit(guest: TurgaiDomain.UserID) async throws {
        guard let runtime else { throw TurgaiWebChatBridgeError.runtimeUnavailable }
        try await Space.resolve(on: runtime.actorSystem, id: runtime.turgaiSpace).admit(guest)
    }

    /// What a person does with spaces, once the runtime runs.
    public func spaces() throws -> Spaces {
        guard let runtime else {
            throw TurgaiWebChatBridgeError.runtimeUnavailable
        }
        return Spaces(actorSystem: runtime.actorSystem, turgaisOwn: runtime.turgaiSpace)
    }

    /// Every Telegram channel there is, in the order they were made.
    public func channelIDs() async throws -> [UUID] {
        guard let runtime else {
            throw TurgaiWebChatBridgeError.runtimeUnavailable
        }
        return try await runtime.channels.ids(TelegramProvider.providerID)
    }

    /// Starts the conversation `conversationID` in `space`, or else Turgai's own, answered by
    /// `agent`, with `person` the first of its people: the space it started in. Refused unless
    /// they're in that space.
    @discardableResult
    public func startConversation(
        _ conversationID: ConversationID, in space: SpaceID?, agent: AgentProfileID, by person: TurgaiDomain.UserID
    ) async throws -> SpaceID {
        guard let runtime else {
            throw TurgaiWebChatBridgeError.runtimeUnavailable
        }
        let startedIn = space ?? runtime.turgaiSpace
        try await Conversation.resolve(on: runtime.actorSystem, conversationID: conversationID)
            .start(in: startedIn, agent: agent, by: person)
        return startedIn
    }

    /// The conversations `person` is in, the one something was last said in first, as the
    /// conversation directory has them: a moment behind the conversations.
    public func conversations(of person: TurgaiDomain.UserID) async throws -> [ConversationListing] {
        guard let runtime else {
            throw TurgaiWebChatBridgeError.runtimeUnavailable
        }
        return try await runtime.actorSystem.singleton
            .proxy(ConversationDirectory.self, name: ConversationDirectory.singletonName)
            .conversations(of: person)
    }

    /// `participant` in the conversation `conversationID`, as `adder`, one of its people, adds them.
    public func add(
        _ participant: Participant, to conversationID: ConversationID, by adder: TurgaiDomain.UserID
    ) async throws {
        guard let runtime else {
            throw TurgaiWebChatBridgeError.runtimeUnavailable
        }
        try await Conversation.resolve(on: runtime.actorSystem, conversationID: conversationID).add(participant, by: adder)
    }

    /// Told about `person`'s conversations as they change, through `onNotice`, until `unfollow`:
    /// the listener the directory tells.
    public func followConversations(
        of person: TurgaiDomain.UserID, onNotice: @escaping @Sendable (ConversationNotice) async -> Void
    ) async throws -> ConversationNoticeListener {
        guard let runtime else {
            throw TurgaiWebChatBridgeError.runtimeUnavailable
        }
        let listener = ConversationNoticeListener(actorSystem: runtime.actorSystem, onNotice: onNotice)
        try await runtime.actorSystem.singleton
            .proxy(ConversationDirectory.self, name: ConversationDirectory.singletonName)
            .follow(person, with: listener)
        return listener
    }

    /// `listener` no longer told anything.
    public func unfollow(_ listener: ConversationNoticeListener) async throws {
        guard let runtime else {
            throw TurgaiWebChatBridgeError.runtimeUnavailable
        }
        try await runtime.actorSystem.singleton
            .proxy(ConversationDirectory.self, name: ConversationDirectory.singletonName)
            .unfollow(listener)
    }

    /// Told when `person`'s memory changes, through `onChange`, until `unfollowMemory`: the
    /// listener the memory passes tell.
    public func followMemory(
        of person: TurgaiDomain.UserID, onChange: @escaping @Sendable () async -> Void
    ) async throws -> MemoryNoticeListener {
        guard let runtime else {
            throw TurgaiWebChatBridgeError.runtimeUnavailable
        }
        let listener = MemoryNoticeListener(actorSystem: runtime.actorSystem, onChange: onChange)
        try await runtime.actorSystem.singleton
            .proxy(MemoryPasses.self, name: MemoryPasses.singletonName)
            .follow(person, with: listener)
        return listener
    }

    /// `listener` no longer told anything.
    public func unfollowMemory(_ listener: MemoryNoticeListener) async throws {
        guard let runtime else {
            throw TurgaiWebChatBridgeError.runtimeUnavailable
        }
        try await runtime.actorSystem.singleton
            .proxy(MemoryPasses.self, name: MemoryPasses.singletonName)
            .unfollow(listener)
    }

    /// What's remembered about `person`, as they see it.
    public func remembered(about person: TurgaiDomain.UserID) async throws -> Remembered {
        guard let runtime else {
            throw TurgaiWebChatBridgeError.runtimeUnavailable
        }
        return try await User.resolve(on: runtime.actorSystem, userID: person).remembered()
    }

    /// Whether what `person` says is remembered.
    public func remembering(of person: TurgaiDomain.UserID) async throws -> Remembering {
        guard let runtime else {
            throw TurgaiWebChatBridgeError.runtimeUnavailable
        }
        return try await User.resolve(on: runtime.actorSystem, userID: person).currentRemembering()
    }

    /// What `person` says remembered from now on, or not.
    public func setRemembering(_ remembering: Remembering, for person: TurgaiDomain.UserID) async throws {
        guard let runtime else {
            throw TurgaiWebChatBridgeError.runtimeUnavailable
        }
        try await User.resolve(on: runtime.actorSystem, userID: person).setRemembering(remembering)
    }

    /// Everything remembered about `person`, forgotten; their conversations stay.
    public func forgetMemory(of person: TurgaiDomain.UserID) async throws {
        guard let runtime else {
            throw TurgaiWebChatBridgeError.runtimeUnavailable
        }
        _ = try await User.resolve(on: runtime.actorSystem, userID: person).forgetMemory()
    }

    /// `person` leaving the conversation `conversationID`: refused unless they're in it.
    public func leave(_ conversationID: ConversationID, as person: TurgaiDomain.UserID) async throws {
        guard let runtime else {
            throw TurgaiWebChatBridgeError.runtimeUnavailable
        }
        try await Conversation.resolve(on: runtime.actorSystem, conversationID: conversationID).leave(person)
    }

    /// The conversation `conversationID` deleted by `person`: by the only one in it, or an admin of
    /// its space.
    public func delete(_ conversationID: ConversationID, by person: TurgaiDomain.UserID) async throws {
        guard let runtime else {
            throw TurgaiWebChatBridgeError.runtimeUnavailable
        }
        try await Conversation.resolve(on: runtime.actorSystem, conversationID: conversationID).delete(by: person)
    }

    /// The conversation `conversationID` called `title`, as `person` titles it: refused unless
    /// they're in it.
    public func title(
        _ conversationID: ConversationID, _ title: ConversationTitle, by person: TurgaiDomain.UserID
    ) async throws {
        guard let runtime else {
            throw TurgaiWebChatBridgeError.runtimeUnavailable
        }
        try await Conversation.resolve(on: runtime.actorSystem, conversationID: conversationID).title(title, by: person)
    }

    /// The conversation `conversationID`, as `person` reads it: refused unless they're one of its
    /// people.
    public func conversation(
        _ conversationID: ConversationID, readBy person: TurgaiDomain.UserID
    ) async throws -> ConversationOutline {
        guard let runtime else {
            throw TurgaiWebChatBridgeError.runtimeUnavailable
        }
        return try await Conversation.resolve(on: runtime.actorSystem, conversationID: conversationID)
            .reading(by: person)
    }

    public func openSession(id: WebSessionID) async throws -> TurgaiConnections.WebSession {
        guard let runtime else {
            throw TurgaiWebChatBridgeError.runtimeUnavailable
        }
        return await runtime.connections.addWebSession(id: id)
    }

    public func configureChannel(_ configuration: ChannelConfiguration<TelegramProvider>) async throws {
        guard let runtime else {
            throw TurgaiWebChatBridgeError.runtimeUnavailable
        }
        let channel = try await TelegramChannel.resolve(
            on: runtime.actorSystem,
            configuration: configuration
        )
        try await channel.replaceConfiguration(configuration)
        try await runtime.channels.add(configuration.id, TelegramProvider.providerID)
    }

    public func channelState(
        for configuration: ChannelConfiguration<TelegramProvider>
    ) async throws -> ChannelState<TelegramProvider> {
        guard let runtime else {
            throw TurgaiWebChatBridgeError.runtimeUnavailable
        }
        let channel = try await TelegramChannel.resolve(
            on: runtime.actorSystem,
            configuration: configuration
        )
        return try await channel.currentState()
    }

    public func channelState(for channelID: UUID) async throws -> ChannelState<TelegramProvider> {
        guard let runtime else {
            throw TurgaiWebChatBridgeError.runtimeUnavailable
        }
        let channel = try await TelegramChannel.resolve(
            on: runtime.actorSystem,
            channelID: channelID
        )
        return try await channel.currentState()
    }

    public func deleteChannel(_ configuration: ChannelConfiguration<TelegramProvider>) async throws {
        guard let runtime else {
            throw TurgaiWebChatBridgeError.runtimeUnavailable
        }
        let channel = try await TelegramChannel.resolve(
            on: runtime.actorSystem,
            configuration: configuration
        )
        try await channel.delete()
        try await runtime.channels.remove(configuration.id)
    }

    public func deleteChannel(id: UUID) async throws {
        guard let runtime else {
            throw TurgaiWebChatBridgeError.runtimeUnavailable
        }
        let channel = try await TelegramChannel.resolve(
            on: runtime.actorSystem,
            channelID: id
        )
        try await channel.delete()
        try await runtime.channels.remove(id)
    }

    /// What's been said in a conversation, as `person` reads it: refused unless they're in it.
    public func conversationHistory(
        of conversationID: ConversationID, for person: TurgaiDomain.UserID
    ) async throws -> [ConversationHistoryEntry] {
        guard let runtime else {
            throw TurgaiWebChatBridgeError.runtimeUnavailable
        }
        return try await runtime.connections.history(of: conversationID, for: person)
    }

    /// The objects `person` may read, as they list them in Turgai's own space: on their behalf.
    public func objects(listedTo person: TurgaiDomain.UserID) async throws -> [ObjectEntry] {
        guard let runtime else {
            throw TurgaiWebChatBridgeError.runtimeUnavailable
        }
        let scope = try await Space.resolve(on: runtime.actorSystem, id: runtime.turgaiSpace).scope(of: person)
        return try await CallChain.$current.withValue(.start(scope, in: nil)) { try await runtime.objectCatalog.entries() }
    }

    /// `person`'s tasks in `space`, those they may change, as they are now; then each change to them,
    /// through `onNotice`, for as long as the returned listener lives. Refused when `person` isn't
    /// in the space.
    public func followTasks(
        in space: SpaceID, of person: TurgaiDomain.UserID,
        onNotice: @escaping @Sendable (TasksNotice) async -> Void
    ) async throws -> (listener: TasksListener, tasks: [KeptTask]) {
        guard let runtime else {
            throw TurgaiWebChatBridgeError.runtimeUnavailable
        }
        let system = runtime.actorSystem
        let scope = try await Space.resolve(on: system, id: space).scope(of: person)
        // Whoever may change a task sees it: whoever made it, and the space's admins.
        let sees: @Sendable (KeptTask) -> Bool = { $0.maker == scope.person || scope.role == .admin }
        // Following first, so no change between this and what's read now is missed.
        let listener = await TasksListener(actorSystem: system, following: space) { notice in
            if case .kept(let task) = notice, !sees(task) { return }
            await onNotice(notice)
        }
        return (listener, try await Self.tasks(in: space, on: system).filter(sees))
    }

    /// `change` to the chat `chat`'s schedule `name`, on behalf of `person`: refused unless they made
    /// it, or are an admin of the chat's space.
    public func changeSchedule(
        _ change: Conversation.TaskChange, named name: String, in chat: ConversationID, by person: TurgaiDomain.UserID
    ) async throws {
        try await inChat(chat, as: person) { system in
            let scheduler = try await Scheduler.resolve(on: system)
            switch change {
            case .pause: _ = try await scheduler.pause(name: name)
            case .resume: _ = try await scheduler.resume(name: name)
            case .cancel: _ = try await scheduler.cancel(name: name)
            }
        }
    }

    /// The chat `chat`'s reminder `name` cancelled, on behalf of `person`: refused unless they set
    /// it, or are an admin of the chat's space.
    public func cancelReminder(named name: String, in chat: ConversationID, by person: TurgaiDomain.UserID)
        async throws
    {
        try await inChat(chat, as: person) { _ = try await Timers.resolve(on: $0).cancel(name: name) }
    }

    /// `act` on behalf of `person`, in the chat `chat`, as they are in its space.
    private func inChat(
        _ chat: ConversationID, as person: TurgaiDomain.UserID, _ act: (ClusterSystem) async throws -> Void
    ) async throws {
        guard let runtime else {
            throw TurgaiWebChatBridgeError.runtimeUnavailable
        }
        let system = runtime.actorSystem
        guard let space = try await Conversation.resolve(on: system, conversationID: chat).spaceID else {
            throw ConversationRefusal.notStarted
        }
        let scope = try await Space.resolve(on: system, id: space).scope(of: person)
        try await CallChain.$current.withValue(.start(scope, in: chat)) { try await act(system) }
    }

    /// What's kept due in `space` now: its chats' schedules and timers, and its objects'.
    private static func tasks(in space: SpaceID, on system: ClusterSystem) async throws -> [KeptTask] {
        let workflows = system.workflows
        let decoder = JSONDecoder()
        var tasks: [KeptTask] = []
        for schedule in try await workflows.listSchedules(workflow: ObjectScheduleWorkflow.self) {
            guard let firing = try? decoder.decode(ObjectFiring.self, from: schedule.inputData), firing.space == space
            else { continue }
            tasks.append(
                KeptTask(
                    id: .schedule(schedule.id), of: .object(firing.object, field: firing.property), due: firing.due,
                    paused: schedule.paused, maker: firing.maker))
        }
        for timer in try await workflows.listWorkflows(workflow: ObjectTimerWorkflow.self) {
            guard case .running = timer.status, let data = timer.inputData,
                let firing = try? decoder.decode(ObjectFiring.self, from: data), firing.space == space
            else { continue }
            tasks.append(
                KeptTask(
                    id: .timer(timer.id), of: .object(firing.object, field: firing.property), due: firing.due,
                    paused: false, maker: firing.maker))
        }
        // A chat's are in its space: found from the chats of whoever made them.
        var chats: [KeptTask] = []
        for schedule in try await workflows.listSchedules(workflow: ScheduleWorkflow.self) {
            guard let made = try? decoder.decode(ChatSchedule.self, from: schedule.inputData) else { continue }
            chats.append(KeptTask(made, id: schedule.id, paused: schedule.paused))
        }
        for timer in try await workflows.listWorkflows(workflow: TimerWorkflow.self) {
            guard case .running = timer.status, let data = timer.inputData,
                let made = try? decoder.decode(ChatTimer.self, from: data)
            else { continue }
            chats.append(KeptTask(made, id: timer.id))
        }
        let directory = try await system.singleton.proxy(
            ConversationDirectory.self, name: ConversationDirectory.singletonName)
        var inSpace: Set<ConversationID> = []
        for maker in Set(chats.map(\.maker)) {
            for chat in try await directory.conversations(of: maker) where chat.space == space {
                inSpace.insert(chat.id)
            }
        }
        return tasks
            + chats.filter { task in
                if case .chat(let chat, _, _) = task.of { inSpace.contains(chat) } else { false }
            }
    }

    /// Shares the object made here as `identity` with everyone, as far as `level`, or takes their
    /// access away, on behalf of `person` in Turgai's own space: refused unless they may change it.
    public func share(
        _ identity: ObjectIdentity, withEveryone level: AccessLevel?, by person: TurgaiDomain.UserID
    ) async throws {
        guard let runtime else {
            throw TurgaiWebChatBridgeError.runtimeUnavailable
        }
        let scope = try await Space.resolve(on: runtime.actorSystem, id: runtime.turgaiSpace).scope(of: person)
        let object = try await DynamicObject.resolve(on: runtime.actorSystem, identity: identity)
        try await CallChain.$current.withValue(.start(scope, in: nil)) { try await object.share(with: .everyone, level) }
    }

    /// The agent's past turns in a conversation, step by step, as `person` asks for them.
    public func conversationTurns(
        of conversationID: ConversationID, askedBy person: TurgaiDomain.UserID
    ) async throws -> [ConversationTurn] {
        guard let runtime else {
            throw TurgaiWebChatBridgeError.runtimeUnavailable
        }
        return try await runtime.connections.turns(of: conversationID, askedBy: person)
    }

    /// Whether a conversation's agent is answering, as `person` sees it: refused unless they're in it.
    public func conversationStatus(
        of conversationID: ConversationID, for person: TurgaiDomain.UserID
    ) async throws -> ConversationStatus {
        guard let runtime else {
            throw TurgaiWebChatBridgeError.runtimeUnavailable
        }
        return try await runtime.connections.status(
            of: conversationID,
            for: person
        )
    }
}

public enum TurgaiWebChatBridgeError: Error, Sendable {
    case runtimeUnavailable
}
