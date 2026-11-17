import Distributed
import DistributedCluster
import TurgaiCalls
import TurgaiConversations
import TurgaiDomain
import TurgaiMemory

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// A space owns its conversations: whoever reaches one reaches it through its space, which settles
/// who's in it, which bots answer and what each turn may do.
extension Space {
    // MARK: Its conversations

    /// Its conversation `id`, which only it reaches.
    func conversation(_ id: ConversationID) async throws -> Conversation {
        try await Conversation.identified(by: id, in: try made().id, on: actorSystem)
    }

    /// What `person` may do in it: refused when they're not in it.
    private func permissions(of person: UserID) throws -> Permissions {
        guard let permissions = try made().permissions(of: person) else { throw SpaceRefusal.notInIt }
        return permissions
    }

    /// Refused once it's archived: it's read, and nothing new is said in it.
    private func inUse() throws {
        guard state.status == .active else { throw ConversationRefusal.spaceArchived }
    }

    /// The conversation `id` started, answered by `bot`, or its main bot when none is asked for,
    /// with `person`, who may use its bots, the first of its people.
    public distributed func start(_ id: ConversationID, with bot: BotID?, by person: UserID) async throws {
        try inUse()
        guard try permissions(of: person).bots != nil else { throw SpaceRefusal.notAllowed }
        let space = try made()
        let answering = bot ?? space.bots.main.id
        guard space.bots[answering] != nil else { throw SpaceRefusal.noSuchBot(answering) }
        try await conversation(id).start(with: answering, by: person)
    }

    /// `message`, said in its conversation by whoever wrote it, one of its people: answered by the
    /// conversation's bot, in the turn `turnID`, when it's said to it.
    public distributed func say(_ message: InboundMessage, turnID: TurnID) async throws {
        try inUse()
        _ = try permissions(of: message.userID)
        let conversation = try await conversation(message.conversationID)
        // A bot it no longer has has left the conversation first.
        if let bot = try await conversation.answeringBot(), try made().bots[bot] == nil {
            try await conversation.botLeft(bot)
        }
        try await conversation.send(message, turnID: turnID, from: self)
    }

    /// `participant` in its conversation `id`, as `adder`, one of its people, adds them: one of its
    /// people, or one of its bots, which `adder` may use.
    public distributed func add(_ participant: Participant, to id: ConversationID, by adder: UserID) async throws {
        try inUse()
        let adding = try permissions(of: adder)
        let space = try made()
        switch participant {
        case .person(let person):
            guard space.permissions(of: person) != nil else { throw SpaceRefusal.notInIt }
        case .bot(let bot):
            guard adding.bots != nil else { throw SpaceRefusal.notAllowed }
            guard space.bots[bot] != nil else { throw SpaceRefusal.noSuchBot(bot) }
        }
        try await conversation(id).add(participant, by: adder)
    }

    /// `person` writing in its conversation `id`'s chat, through one of its connections: one of its
    /// members, unless they're in it already, and one of the conversation's people, which starts the
    /// first time, answered by its main bot.
    public distributed func followChat(_ id: ConversationID, by person: UserID) async throws {
        try inUse()
        try await admit(person, into: NonEmptySet(.members))
        try await conversation(id).follow(by: person, startingWith: try made().bots.main.id)
    }

    /// `person` in its conversation `id`, as the platform of its chat says: one of its members too,
    /// unless they're in it already.
    public distributed func admitToChat(_ person: UserID, in id: ConversationID) async throws {
        try inUse()
        try await admit(person, into: NonEmptySet(.members))
        try await conversation(id).admit(person)
    }

    /// `person` leaving its conversation `id`.
    public distributed func leave(_ id: ConversationID, as person: UserID) async throws {
        try await conversation(id).leave(person)
    }

    /// Its conversation `id` deleted by `person`: by the only one in it, or by someone who may
    /// delete anyone's here.
    public distributed func delete(_ id: ConversationID, by person: UserID) async throws {
        let mayDeleteAny = try permissions(of: person).deleteConversations
        try await conversation(id).delete(by: person, mayDeleteAny: mayDeleteAny)
    }

    /// Its conversation `id` called `title`, as `person`, one of its people, titles it.
    public distributed func title(_ id: ConversationID, _ title: ConversationTitle, by person: UserID) async throws {
        _ = try permissions(of: person)
        try await conversation(id).title(title, by: person)
    }

    /// Its conversation `id` emptied by `person`, one of its people.
    public distributed func reset(_ id: ConversationID, by person: UserID) async throws {
        _ = try permissions(of: person)
        try await conversation(id).reset(by: person)
    }

    // MARK: Watching its conversations

    /// `connection` told what happens in its conversation `id` from now on, for `person`, one of
    /// its people: shown what still waits for an answer here, too.
    public distributed func open(_ id: ConversationID, to connection: ConversationConnection, for person: UserID)
        async throws
    {
        _ = try permissions(of: person)
        let conversation = try await conversation(id)
        _ = try await conversation.reading(by: person)
        try await conversation.addConnection(connection, waiting: waiting(), from: self)
    }

    /// `connection`, its conversation `id`'s chat through one of its connections, told what happens
    /// in it from now on, for everyone in the chat.
    public distributed func openChat(_ id: ConversationID, to connection: ConversationConnection) async throws {
        try await conversation(id).addConnection(connection, waiting: waiting(), from: self)
    }

    /// `connection` no longer told what happens in its conversation `id`.
    public distributed func close(_ id: ConversationID, to connection: ConversationConnection) async throws {
        try await conversation(id).removeConnection(connection)
    }

    /// `text` told in its conversation `id`, as something it runs on its people's behalf, such as
    /// a reminder, says.
    public distributed func notify(_ id: ConversationID, _ text: String) async throws {
        try await conversation(id).notify(text)
    }

    /// `message` marked in its conversation as noted for its author's memory.
    public distributed func noted(_ message: NotedMessage, in id: ConversationID) async throws {
        try await conversation(id).noted(message)
    }

    /// `text` shown in its conversation `id`, with `actions` its people can take: an answer to a
    /// command someone gave in it.
    public distributed func showNotice(_ text: String, actions: [OutboundAction], in id: ConversationID) async throws {
        try await conversation(id).showNotice(text, actions: actions)
    }

    // MARK: Reading its conversations

    /// Its conversation `id`, as `person` reads it.
    public distributed func reading(_ id: ConversationID, by person: UserID) async throws -> ConversationOutline {
        _ = try permissions(of: person)
        return try await conversation(id).reading(by: person)
    }

    /// What's been said in its conversation `id`, as `person` reads it.
    public distributed func history(of id: ConversationID, for person: UserID) async throws
        -> [ConversationHistoryEntry]
    {
        _ = try permissions(of: person)
        return try await conversation(id).history(for: person)
    }

    /// Whether its conversation `id`'s bot is answering, as `person` sees it.
    public distributed func status(of id: ConversationID, for person: UserID) async throws -> ConversationStatus {
        _ = try permissions(of: person)
        return try await conversation(id).status(for: person)
    }

    /// Where its conversation `id`'s past turns are, as `person` asks for them.
    public distributed func agentTurns(of id: ConversationID, for person: UserID) async throws
        -> ConversationAgentTurns
    {
        _ = try permissions(of: person)
        return try await conversation(id).agentTurns(askedBy: person)
    }

    /// The bot that answers in its conversation `id`, as it has it now: none until it has started,
    /// or once the bot has left.
    public distributed func answeringBot(of id: ConversationID) async throws -> Bot? {
        guard let bot = try await conversation(id).answeringBot() else { return nil }
        return try made().bots[bot]
    }

    // MARK: Commands given in its conversations

    /// What's remembered about `person`, shown in its conversation `id`.
    public distributed func showMemory(in id: ConversationID, for person: UserID) async throws {
        _ = try permissions(of: person)
        try await conversation(id).showMemory(for: person)
    }

    /// `person`'s remembered fact `written` forgotten, from its conversation `id`.
    public distributed func forgetFact(_ written: String, in id: ConversationID, for person: UserID) async throws {
        _ = try permissions(of: person)
        try await conversation(id).forgetFact(written, for: person)
    }

    /// Remembering what `person` says turned on or off, from its conversation `id`.
    public distributed func setRemembering(_ remembering: Remembering, in id: ConversationID, for person: UserID)
        async throws
    {
        _ = try permissions(of: person)
        try await conversation(id).setRemembering(remembering, for: person)
    }

    /// Everything remembered about `person` forgotten, from its conversation `id`.
    public distributed func forgetMemory(in id: ConversationID, for person: UserID) async throws {
        _ = try permissions(of: person)
        try await conversation(id).forgetMemory(for: person)
    }

    /// What the bot of its conversation `id` holds in its context, shown to `person`.
    public distributed func showContext(in id: ConversationID, for person: UserID) async throws {
        try await conversation(id).showContext(as: try made().scope(of: person))
    }

    /// The bot of its conversation `id` trying each of its tools, as `person` asks.
    public distributed func showDiagnostics(in id: ConversationID, for person: UserID) async throws {
        try inUse()
        _ = try permissions(of: person)
        try await conversation(id).showDiagnostics(for: person, from: self)
    }
}
