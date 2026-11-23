import Crypto
import DistributedCluster
import DurableWorkflows
import EventSourcing
import HTTPTypes
import Hail
import Hummingbird
import HummingbirdWebSocket
import NIOCore
import TurgaiAgents
import TurgaiApplication
import TurgaiCalls
import TurgaiConversations
import TurgaiDomain
import TurgaiHail
import TurgaiMemory
import TurgaiModels
import TurgaiObjects
import TurgaiPeople
import TurgaiSpaces
import TurgaiTelegram

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// Where the conversations of Turgai's own apps are: each by the id it's given as it starts.
let turgaiChannel = ChannelID("turgai")

extension TurgaiMainWebApp {
    func registerPublicChatRoutes(
        on router: Router<BasicWebSocketRequestContext>,
        dependencies: TurgaiRouteDependencies
    ) {
        // Every API call comes from a client the API's configuration lets in.
        let api = router.group("api/v1").add(
            middleware: PublicAPIAuthorization(configuration: dependencies.apiConfiguration))
        // Someone who doesn't sign in, coming into a space as a guest, in its guests group: allowed
        // what its admins allow that group, nothing unless they do. With the cookie that says
        // they're them from now on.
        api.post("spaces/:space/guests") { _, context in
            guard let id = spaceID(in: context) else { return noSuchSpace() }
            let space = try await Space.identified(by: id, on: dependencies.system)
            guard try await space.status() != nil else { return noSuchSpace() }
            let (guest, token) = try await dependencies.auth.newGuest()
            try await space.admit(guest, into: NonEmptySet(.guests))
            var response = Response(status: .created)
            response.setCookie(TurgaiWebSupport.guestCookie(token))
            return response
        }
        // Who's signed in: their id and name.
        api.get("me") { request, _ in
            guard let person = await signedInPerson(from: request, auth: dependencies.auth) else {
                return signInRequired()
            }
            let names = ParticipantNames(auth: dependencies.auth, in: nil)
            return try publicAPIResponse(Me(id: person.key, name: try await names.name(of: .person(person))))
        }
        // What's remembered about whoever's signed in, and whether they're remembered; remembering
        // turned on or off; and all of it forgotten.
        api.get("me/memory") { request, _ in
            guard let person = await signedInPerson(from: request, auth: dependencies.auth) else {
                return signInRequired()
            }
            return try publicAPIResponse(try await memory(of: person, on: dependencies.system))
        }
        api.put("me/memory/remembering") { request, context in
            guard let person = await signedInPerson(from: request, auth: dependencies.auth) else {
                return signInRequired()
            }
            let input = try await body(SetRememberingRequest.self, of: request, context: context)
            try await User.identified(by: person, on: dependencies.system).setRemembering(
                Remembering(input.remembering))
            return Response(status: .noContent)
        }
        api.delete("me/memory") { request, _ in
            guard let person = await signedInPerson(from: request, auth: dependencies.auth) else {
                return signInRequired()
            }
            _ = try await User.identified(by: person, on: dependencies.system).forgetMemory()
            return Response(status: .noContent)
        }
        // What a provider offers, asked with what's chosen so far for a bot's model: with the key
        // typed, or else the one the bot named keeps, when it's for the same place.
        api.post("models") { request, context in
            guard let person = await signedInPerson(from: request, auth: dependencies.auth) else {
                return signInRequired()
            }
            let input = try await body(ModelsRequest.self, of: request, context: context)
            var saved: AgentProviderConfiguration?
            if let space = input.spaceID.flatMap(TurgaiDomain.SpaceID.init), let id = input.botID,
                let bot = TurgaiDomain.BotID(id.rawValue)
            {
                saved = try? await Space.identified(by: space, on: dependencies.system).bots(for: person)
                    .first { $0.id == bot }?.model.location
            }
            let draft = AgentDraft(
                BotConfiguration(
                    name: "", instructions: "",
                    model: ModelChoice(
                        provider: input.provider, address: input.address, apiKey: input.apiKey, model: "")))
            let answer: ModelsAnswer =
                switch await ModelSearch.search(draft, saved: saved, credentials: dependencies.agentCredentials) {
                case .found(let models): .found(models.map(\.rawValue))
                case .invalid(let field): .unavailable("The \(field) isn't valid.")
                case .unavailable(let reason): .unavailable(reason.sentence)
                }
            return try publicAPIResponse(answer)
        }
        registerConversations(on: api.group("conversations"), dependencies: dependencies)
        registerLinks(on: api.group("me/links"), dependencies: dependencies)
        registerSpaces(on: api.group("spaces"), dependencies: dependencies)
        registerChatSocket(on: router, dependencies: dependencies)
        registerLiveSocket(on: router, dependencies: dependencies)
    }

    /// The web chat page's conversation, over a WebSocket, as HTML. Not behind the API's middleware:
    /// a socket it refuses isn't upgraded, rather than answered.
    private func registerChatSocket(
        on router: Router<BasicWebSocketRequestContext>, dependencies: TurgaiRouteDependencies
    ) {
        router.ws("/api/v1/chat") { request, _ in
            // Only one of a conversation's people opens it.
            guard dependencies.apiConfiguration.authorizes(request),
                let owner = await chatOwner(from: request, auth: dependencies.auth),
                try await apiConversation(
                    request.uri.queryParameters["conversationID"].map(String.init),
                    in: request.uri.queryParameters["space"].map(String.init), readBy: owner.person,
                    dependencies: dependencies) != nil
            else {
                return .dontUpgrade
            }
            return .upgrade([:])
        } onUpgrade: { inbound, outbound, context in
            guard let owner = await chatOwner(from: context.request, auth: dependencies.auth),
                let conversation = try await apiConversation(
                    context.request.uri.queryParameters["conversationID"].map(String.init),
                    in: context.request.uri.queryParameters["space"].map(String.init), readBy: owner.person,
                    dependencies: dependencies)
            else {
                try await outbound.close(.policyViolation, reason: "Conversation not found")
                return
            }
            let session = LiveSession(
                id: UUID().uuidString, actorSystem: dependencies.system, linking: dependencies.linking, source: .web)
            // It runs while the socket does: its input finishes as the socket closes.
            async let _: Void = session.run()
            let userID = owner.person
            let names = ParticipantNames(auth: dependencies.auth, in: conversation.space, on: dependencies.system)
            do {
                let history = try await publicAPIMessages(
                    try await conversation.reached(on: dependencies.system).history(
                        of: conversation.domainID, for: userID),
                    names: names)
                let status = try await conversation.reached(on: dependencies.system).status(
                    of: conversation.domainID, for: userID)
                // The durable snapshot before live delivery, which could otherwise come first and be
                // replaced by it.
                let writer = HTMLChatSocketWriter(outbound: outbound, viewer: userID, names: names)
                try await writer.write(ChatLiveFragment.history(history.map { $0.shown(to: userID) }))
                if case .running = status {
                    try await writer.write(ChatLiveFragment.started())
                }
                guard try await open(conversation, for: userID, on: session) else {
                    session.input.finish()
                    try await outbound.close(.policyViolation, reason: "Could not open conversation")
                    return
                }
                try await runHTMLChatSocket(
                    inbound: inbound,
                    outbound: outbound,
                    session: session,
                    conversation: conversation,
                    participantID: ParticipantID(channel: turgaiChannel, rawValue: userID.key),
                    userID: userID,
                    names: names
                )
            } catch {
                try? await outbound.close(.goingAway, reason: "Chat connection ended")
            }
            session.input.finish()
        }
    }

    /// An app's one connection, over a WebSocket: the conversation it has open, with its history and
    /// live turns, and notices about the person's other conversations. Not behind the API's
    /// middleware: a socket it refuses isn't upgraded, rather than answered.
    private func registerLiveSocket(
        on router: Router<BasicWebSocketRequestContext>, dependencies: TurgaiRouteDependencies
    ) {
        router.ws("/api/v1/live") { request, _ in
            guard dependencies.apiConfiguration.authorizes(request),
                await chatOwner(from: request, auth: dependencies.auth) != nil
            else {
                return .dontUpgrade
            }
            return .upgrade([:])
        } onUpgrade: { inbound, outbound, context in
            guard let owner = await chatOwner(from: context.request, auth: dependencies.auth) else {
                try await outbound.close(.policyViolation, reason: "Sign in first")
                return
            }
            let session = LiveSession(
                id: UUID().uuidString, actorSystem: dependencies.system, linking: dependencies.linking, source: .web)
            // It runs while the socket does: its input finishes as the socket closes.
            async let _: Void = session.run()
            let person = owner.person
            let writer = PublicChatSocketWriter(outbound: outbound)
            let shown = ShownConversation()
            do {
                // Notices about the person's conversations in Turgai's apps. What's said in the one
                // it has open, and leaving it, come as that conversation's own events.
                let directory = try await dependencies.system.singleton.proxy(
                    ConversationDirectory.self, name: ConversationDirectory.singletonName)
                let notices = try await directory.subscription(for: person)
                @Sendable func tell(_ notice: ConversationNotice) async {
                    let payload: TurgaiModels.ChatEvent.Payload?
                    switch notice {
                    case .joined(let listing) where listing.id.channel == turgaiChannel:
                        payload = .conversationJoined(conversation: .init(listing))
                    case .said(let listing) where listing.id.channel == turgaiChannel:
                        let open = await shown.conversation?.domainID == listing.id
                        payload = open ? nil : .conversationSaid(conversation: .init(listing))
                    case .titled(let listing) where listing.id.channel == turgaiChannel:
                        payload = .conversationTitled(conversation: .init(listing))
                    case .left(let conversation) where conversation.channel == turgaiChannel:
                        let open = await shown.conversation?.domainID == conversation
                        let id = TurgaiModels.ConversationID(rawValue: conversation.externalAddress.rawValue)
                        payload = open ? nil : .conversationLeft(conversationID: id)
                    case .deleted(let conversation) where conversation.channel == turgaiChannel:
                        // The open one too: what it showed is gone.
                        let id = TurgaiModels.ConversationID(rawValue: conversation.externalAddress.rawValue)
                        payload = .conversationDeleted(conversationID: id)
                    case .joined, .said, .titled, .left, .deleted:
                        payload = nil
                    }
                    guard let payload else { return }
                    try? await writer.write(.init(payload: payload))
                }
                let telling = Task {
                    for await notice in notices { await tell(notice) }
                }
                defer {
                    telling.cancel()
                    await notices.cancel()
                }
                // The person's spaces as they change: each as it lists itself for them now.
                let spaces = try await dependencies.system.singleton.proxy(
                    SpaceDirectory.self, name: SpaceDirectory.singletonName
                ).subscription(for: person)
                let system = dependencies.system
                let spacesTelling = Task {
                    for await notice in spaces {
                        let payload: TurgaiModels.ChatEvent.Payload?
                        switch notice {
                        case .joined(let id):
                            payload = try? await Space.identified(by: id, on: system).listing(for: person).map {
                                .spaceJoined(space: SpaceSummary($0))
                            }
                        case .listed(let id):
                            payload = try? await Space.identified(by: id, on: system).listing(for: person).map {
                                .spaceListed(space: SpaceSummary($0))
                            }
                        case .left(let id):
                            payload = .spaceLeft(spaceID: id.api)
                        }
                        guard let payload else { continue }
                        try? await writer.write(.init(payload: payload))
                    }
                }
                defer {
                    spacesTelling.cancel()
                    Task { await spaces.cancel() }
                }
                // What it's told about besides the conversation it shows, while it's joined.
                let topics = JoinedTopics()
                defer { await topics.leaveAll() }

                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask {
                        for try await input in inbound.messages(maxSize: 1_000_000) {
                            guard case .text(let text) = input,
                                let data = text.data(using: .utf8),
                                let command = try? JSONDecoder().decode(TurgaiModels.ChatCommand.self, from: data)
                            else { continue }
                            switch command {
                            case .open(let space, let id):
                                guard
                                    let conversation = try await apiConversation(
                                        id.rawValue, in: space.rawValue, readBy: person, dependencies: dependencies)
                                else {
                                    try await writer.write(
                                        publicAPIErrorEvent(
                                            conversationID: id, code: "conversation_not_found",
                                            message: "The conversation does not exist."))
                                    continue
                                }
                                if let before = await shown.conversation {
                                    let detached = ConversationInputReceipt()
                                    await session.input.send(
                                        ConversationInputDelivery(
                                            in: before.space, input: .detach(before.domainID), receipt: detached))
                                    _ = await detached.wait()
                                }
                                await shown.show(conversation)
                                try await writeOpened(
                                    conversation, for: person, on: writer, names: conversation.names,
                                    dependencies: dependencies)
                                guard try await open(conversation, for: person, on: session) else {
                                    try await writer.write(
                                        publicAPIErrorEvent(
                                            conversationID: id, code: "conversation_unavailable",
                                            message: "The conversation could not be opened."))
                                    continue
                                }
                            case .message(let request):
                                guard let conversation = await shown.conversation else { continue }
                                try await say(request, in: conversation, as: person, on: session, writer: writer)
                            case .answer(let id, let answer):
                                guard let conversation = await shown.conversation else { continue }
                                let receipt = ConversationInputReceipt()
                                await session.input.send(
                                    ConversationInputDelivery(
                                        in: conversation.space,
                                        input: .answer(
                                            conversationID: conversation.domainID, AccessRequestID(id), answer.domain,
                                            by: person),
                                        receipt: receipt))
                                _ = await receipt.wait()
                            case .push(let ref, let ask):
                                let reply = await answer(
                                    ask, for: person, topics: topics, writer: writer, dependencies: dependencies)
                                try await writer.write(.init(payload: .reply(ref: ref, reply: reply)))
                            }
                        }
                    }
                    group.addTask {
                        for await delivery in session.output {
                            // Only the open conversation's: one closed may still be heard a moment.
                            if let conversation = await shown.conversation,
                                delivery.event.conversationID == conversation.domainID,
                                let event = PublicChatEvent(
                                    event: delivery.event,
                                    publicConversationID: conversation.publicID,
                                    author: try await author(
                                        of: delivery.event, answeredBy: conversation.bot?.id,
                                        names: conversation.names)
                                ).event
                            {
                                try await writer.write(event)
                            }
                            await delivery.delivered()
                        }
                    }
                    _ = try await group.next()
                    group.cancelAll()
                }
            } catch {
                try? await outbound.close(.goingAway, reason: "Chat connection ended")
            }
            session.input.finish()
        }
    }

    /// The API's conversations: the person's own, starting one, reading one, titling it, and
    /// leaving it.
    private func registerConversations(
        on conversations: RouterGroup<BasicWebSocketRequestContext>, dependencies: TurgaiRouteDependencies
    ) {
        // The person's conversations in Turgai's apps, the one something was last said in first.
        conversations.get { request, _ in
            guard let owner = await chatOwner(from: request, auth: dependencies.auth) else { return signInRequired() }
            let listed = try await dependencies.system.singleton
                .proxy(ConversationDirectory.self, name: ConversationDirectory.singletonName)
                .conversations(of: owner.person)
            return try publicAPIResponse(
                listed.filter { $0.id.channel == turgaiChannel }.map(TurgaiModels.Conversation.init))
        }

        // A new conversation, in a space the person is in, with them its first:
        // answered by the bot asked for, or the space's main one.
        conversations.post { request, context in
            guard let owner = await chatOwner(from: request, auth: dependencies.auth) else { return signInRequired() }
            let input = try await body(TurgaiModels.CreateConversationRequest.self, of: request, context: context)
            guard let startedIn = TurgaiDomain.SpaceID(input.spaceID) else { return noSuchSpace() }
            let bot: TurgaiDomain.BotID?
            if let written = input.botID {
                guard let id = TurgaiDomain.BotID(written.rawValue) else { return noSuchBot() }
                bot = id
            } else {
                bot = nil
            }
            let conversationID = TurgaiDomain.ConversationID(
                channel: turgaiChannel, externalAddress: .init(UUID().uuidString))
            let space = try await Space.identified(by: startedIn, on: dependencies.system)
            do {
                try await space.start(conversationID, with: bot, by: owner.person)
            } catch let refusal as SpaceRefusal {
                return spaceRefused(refusal)
            } catch let refusal as ConversationRefusal {
                return conversationRefused(refusal)
            }
            return try publicAPIResponse(
                TurgaiModels.Conversation(
                    id: .init(rawValue: conversationID.externalAddress.rawValue),
                    botID: try await space.answeringBot(of: conversationID).map { .init(rawValue: $0.id.role) },
                    spaceID: startedIn.api, people: 1),
                status: .created
            )
        }
    }

    /// One of a space's conversations, through the API, by the space and the id it was given: reading
    /// it, titling it, who's in it, adding someone, and leaving it.
    private func registerSpaceConversations(
        on conversations: RouterGroup<BasicWebSocketRequestContext>, dependencies: TurgaiRouteDependencies
    ) {
        /// The conversation `context` names, as `person` reads it.
        @Sendable func named(in context: BasicWebSocketRequestContext, readBy person: TurgaiDomain.UserID)
            async throws -> APIConversation?
        {
            try await apiConversation(
                context.parameters.get("id"), in: context.parameters.get("space"), readBy: person,
                dependencies: dependencies)
        }

        conversations.get(":id") { request, context in
            guard let owner = await chatOwner(from: request, auth: dependencies.auth) else { return signInRequired() }
            guard let conversation = try await named(in: context, readBy: owner.person) else {
                return conversationNotFound()
            }
            return try publicAPIResponse(conversation.info)
        }

        conversations.patch(":id") { request, context in
            guard let owner = await chatOwner(from: request, auth: dependencies.auth) else { return signInRequired() }
            guard let conversation = try await named(in: context, readBy: owner.person) else {
                return conversationNotFound()
            }
            let input = try await body(TurgaiModels.TitleConversationRequest.self, of: request, context: context)
            guard let title = ConversationTitle(input.title) else {
                return publicAPIErrorResponse(
                    status: .badRequest, code: "invalid_title",
                    message: "A conversation's title is some words, at most \(ConversationTitle.maximumLength) letters."
                )
            }
            try await conversation.reached(on: dependencies.system).title(
                conversation.domainID, title, by: owner.person)
            return Response(status: .noContent)
        }

        // Who's in it: its bot, and its people.
        conversations.get(":id/participants") { request, context in
            guard let owner = await chatOwner(from: request, auth: dependencies.auth) else { return signInRequired() }
            guard let conversation = try await named(in: context, readBy: owner.person) else {
                return conversationNotFound()
            }
            var participants: [ParticipantSummary] = []
            for participant in conversation.outline.participants {
                participants.append(try await conversation.names.summary(of: participant))
            }
            return try publicAPIResponse(
                participants.sorted { ($0.kind == .agent ? 0 : 1, $0.name) < ($1.kind == .agent ? 0 : 1, $1.name) })
        }

        // Someone added by one of its people: a person of its space, or one of its bots.
        conversations.post(":id/participants") { request, context in
            guard let owner = await chatOwner(from: request, auth: dependencies.auth) else { return signInRequired() }
            guard let conversation = try await named(in: context, readBy: owner.person) else {
                return conversationNotFound()
            }
            let input = try await body(ParticipantRef.self, of: request, context: context)
            guard let participant = Participant(input) else { return noSuchParticipant() }
            do {
                try await conversation.reached(on: dependencies.system).add(
                    participant, to: conversation.domainID, by: owner.person)
            } catch let refusal as ConversationRefusal {
                return conversationRefused(refusal)
            } catch let refusal as SpaceRefusal {
                return spaceRefused(refusal)
            }
            return Response(status: .noContent)
        }

        // The person leaving it: it's off their list, and they no longer read it.
        conversations.delete(":id/me") { request, context in
            guard let owner = await chatOwner(from: request, auth: dependencies.auth) else { return signInRequired() }
            guard let conversation = try await named(in: context, readBy: owner.person) else {
                return conversationNotFound()
            }
            try await conversation.reached(on: dependencies.system).leave(conversation.domainID, as: owner.person)
            return Response(status: .noContent)
        }
    }

    /// The signed-in person's other ways in: listing them, a code for one to enter, entering a
    /// code one got, and unlinking one.
    private func registerLinks(
        on links: RouterGroup<BasicWebSocketRequestContext>, dependencies: TurgaiRouteDependencies
    ) {
        let auth = dependencies.auth
        let linking = dependencies.linking

        links.get { request, _ in
            guard let person = await signedInPerson(from: request, auth: auth) else { return signInRequired() }
            return try publicAPIResponse(try await linking.pairedWith(person).compactMap(LinkedPerson.init))
        }

        links.post("codes") { request, _ in
            guard let person = await signedInPerson(from: request, auth: auth) else { return signInRequired() }
            let now = Date()
            let code = try await linking.code(for: person, now: now)
            return try publicAPIResponse(
                LinkCodeOffer(code: code.description, expiresAt: now.addingTimeInterval(PersonLinking.codeLifetime)),
                status: .created)
        }

        links.post { request, context in
            guard let person = await signedInPerson(from: request, auth: auth) else { return signInRequired() }
            let input = try await body(EnterLinkCodeRequest.self, of: request, context: context)
            guard let code = LinkCode(input.code) else {
                return publicAPIErrorResponse(
                    status: .badRequest, code: "not_a_code", message: PersonLinkingError.codeDoesNotWork.description)
            }
            do {
                let other = try await linking.link(person, using: code)
                guard let linked = LinkedPerson(other) else { return Response(status: .noContent) }
                return try publicAPIResponse(linked, status: .created)
            } catch let error as PersonLinkingError {
                return publicAPIErrorResponse(
                    status: .conflict, code: "code_does_not_work", message: error.description)
            }
        }

        links.delete(":person") { request, context in
            guard let person = await signedInPerson(from: request, auth: auth) else { return signInRequired() }
            guard let key = context.parameters.get("person"), let other = try? TurgaiDomain.UserID(key: key) else {
                return publicAPIErrorResponse(
                    status: .notFound, code: "not_linked", message: "No one like that is linked.")
            }
            try await linking.unlink(person, from: other)
            return Response(status: .noContent)
        }
    }

    /// The signed-in person's spaces: their list, making one, renaming it, leaving it, inviting
    /// someone, the invites that work, taking one back, and joining with one.
    /// Everything under `/spaces`: the spaces themselves, their bots, people and connections here,
    /// and their conversations, messages and objects in parts of their own.
    private func registerSpaces(
        on spaces: RouterGroup<BasicWebSocketRequestContext>, dependencies: TurgaiRouteDependencies
    ) {
        registerSpaceConversations(on: spaces.group(":space/conversations"), dependencies: dependencies)
        registerMessages(on: spaces.group(":space/conversations/:id/messages"), dependencies: dependencies)
        registerSpaceObjects(on: spaces, dependencies: dependencies)
        let auth = dependencies.auth
        let system = dependencies.system

        /// What `request`'s person asks of spaces, refused when no one signed in, and said back as
        /// the API says it.
        @Sendable func answering(
            _ request: Request, _ answer: (TurgaiDomain.UserID) async throws -> Response
        ) async throws -> Response {
            guard let person = await signedInPerson(from: request, auth: auth) else { return signInRequired() }
            do {
                return try await answer(person)
            } catch let refusal as SpaceRefusal {
                return spaceRefused(refusal)
            }
        }

        /// The space `id`, as `person`'s list shows it, the API's way: refused when they're not in it.
        @Sendable func summary(of space: Space, for person: TurgaiDomain.UserID) async throws -> SpaceSummary {
            guard let listing = try await space.listing(for: person) else { throw SpaceRefusal.notInIt }
            return SpaceSummary(listing)
        }

        // The spaces they're in, the first joined first, each as it lists itself for them.
        spaces.get { request, _ in
            try await answering(request) { person in
                let ids = try await system.singleton.proxy(SpaceDirectory.self, name: SpaceDirectory.singletonName)
                    .spaces(of: person)
                var listed: [SpaceSummary] = []
                for id in ids {
                    // One they've left since the directory read it isn't theirs.
                    guard let listing = try await Space.identified(by: id, on: system).listing(for: person) else {
                        continue
                    }
                    listed.append(SpaceSummary(listing))
                }
                return try publicAPIResponse(listed)
            }
        }

        spaces.post { request, context in
            try await answering(request) { person in
                let input = try await body(MakeSpaceRequest.self, of: request, context: context)
                guard let name = SpaceName(input.name) else { return nameRequired() }
                // Its first bot, its model checked where it runs; a key typed now is kept first, and
                // let go when the space isn't made.
                let made: (bot: TurgaiDomain.Bot, newKey: (reference: AgentCredentialReference, value: String)?)
                do {
                    made = try await AgentDraft(input.bot).bot(over: nil, credentials: dependencies.agentCredentials)
                } catch {
                    return publicAPIErrorResponse(
                        status: .badRequest, code: "invalid_bot", message: TurgaiWebSupport.profileErrorMessage(error))
                }
                if let newKey = made.newKey {
                    try await dependencies.agentCredentials.save(newKey.value, for: newKey.reference)
                }
                let id = TurgaiDomain.SpaceID()
                let space = try await Space.identified(by: id, on: system)
                do {
                    // It starts with every built-in object there is.
                    try await space.make(
                        named: name, by: person, bot: made.bot)
                } catch {
                    if let newKey = made.newKey { try? await dependencies.agentCredentials.remove(newKey.reference) }
                    throw error
                }
                return try publicAPIResponse(try await summary(of: space, for: person), status: .created)
            }
        }

        spaces.patch(":space") { request, context in
            try await answering(request) { person in
                guard let id = spaceID(in: context) else { return noSuchSpace() }
                let input = try await body(RenameSpaceRequest.self, of: request, context: context)
                guard let name = SpaceName(input.name) else { return nameRequired() }
                let space = try await Space.identified(by: id, on: system)
                try await space.rename(to: name, by: person)
                return try publicAPIResponse(try await summary(of: space, for: person))
            }
        }

        spaces.delete(":space/me") { request, context in
            try await answering(request) { person in
                guard let id = spaceID(in: context) else { return noSuchSpace() }
                try await Space.identified(by: id, on: system).leave(person)
                return Response(status: .noContent)
            }
        }

        spaces.post(":space/invites") { request, context in
            try await answering(request) { person in
                guard let id = spaceID(in: context) else { return noSuchSpace() }
                let input = try await body(MakeInviteRequest.self, of: request, context: context)
                let lifetime: SpaceInviteLifetime
                switch input.validForDays {
                case nil: lifetime = .untilUsed
                case let days? where days >= 1:
                    lifetime = .until(Date().addingTimeInterval(TimeInterval(days) * 86_400))
                case _?:
                    return publicAPIErrorResponse(
                        status: .badRequest, code: "invalid_days", message: "An invite works for a day or more.")
                }
                // The token its link carries: only this answer ever holds it, and the space its hash.
                let token = SpaceInviteToken.new()
                let invite = SpaceInvite(hash: token.hash, by: person, lifetime: lifetime)
                try await Space.identified(by: id, on: system).invite(invite)
                return try publicAPIResponse(
                    SpaceInviteOffer(
                        id: invite.id.rawValue.uuidString, token: token.rawValue,
                        link: SpaceInviteLink(spaceID: id.api, token: token.rawValue).description,
                        expiresAt: invite.expiresAt),
                    status: .created)
            }
        }

        let credentials = dependencies.agentCredentials

        /// The bot `configuration` describes, `saved` changed or a new one, its model checked where
        /// it runs, saved by `save`: a key typed now is kept first, and let go when it isn't saved;
        /// the key it replaces is let go once it is. Why it's refused, when it is.
        @Sendable func saving(
            _ configuration: BotConfiguration, over saved: TurgaiDomain.Bot?,
            _ save: (TurgaiDomain.Bot) async throws -> Void
        ) async throws -> Response? {
            let made: (bot: TurgaiDomain.Bot, newKey: (reference: AgentCredentialReference, value: String)?)
            do {
                made = try await AgentDraft(configuration).bot(over: saved, credentials: credentials)
            } catch {
                return publicAPIErrorResponse(
                    status: .badRequest, code: "invalid_bot", message: TurgaiWebSupport.profileErrorMessage(error))
            }
            if let newKey = made.newKey { try await credentials.save(newKey.value, for: newKey.reference) }
            do {
                try await save(made.bot)
            } catch {
                if let newKey = made.newKey { try? await credentials.remove(newKey.reference) }
                throw error
            }
            if let old = saved?.model.location.credentialReference, old != made.bot.model.location.credentialReference {
                try? await credentials.remove(old)
            }
            return nil
        }

        /// The bot `context` names, of the space it names, as `person`, who may use its bots, sees it.
        @Sendable func named(in context: BasicWebSocketRequestContext, for person: TurgaiDomain.UserID)
            async throws -> (Space, TurgaiDomain.Bot)?
        {
            guard let id = spaceID(in: context),
                let bot = context.parameters.get("bot").flatMap({ TurgaiDomain.BotID($0) })
            else { return nil }
            let space = try await Space.identified(by: id, on: system)
            guard let found = try await space.bots(for: person).first(where: { $0.id == bot }) else { return nil }
            return (space, found)
        }

        // Its bots, the main first, as the person, who may use them, sees them: each with its
        // configuration, but its key.
        spaces.get(":space/bots") { request, context in
            try await answering(request) { person in
                guard let id = spaceID(in: context) else { return noSuchSpace() }
                let bots = try await Space.identified(by: id, on: system).bots(for: person)
                return try publicAPIResponse(bots.enumerated().map { SpaceBot($1, isMain: $0 == 0) })
            }
        }

        // A bot added, as the person, who may configure its bots, adds it.
        spaces.post(":space/bots") { request, context in
            try await answering(request) { person in
                guard let id = spaceID(in: context) else { return noSuchSpace() }
                let input = try await body(BotConfiguration.self, of: request, context: context)
                let space = try await Space.identified(by: id, on: system)
                let added = Added()
                if let refused = try await saving(
                    input, over: nil,
                    { bot in
                        try await space.addBot(bot, by: person)
                        await added.keep(bot)
                    })
                {
                    return refused
                }
                guard let bot = await added.bot else { return noSuchBot() }
                return try publicAPIResponse(SpaceBot(bot, isMain: false), status: .created)
            }
        }

        // A bot as it's configured from now on, as the person, who may configure its bots, changes
        // it: its saved key kept when none is typed.
        spaces.patch(":space/bots/:bot") { request, context in
            try await answering(request) { person in
                guard let (space, saved) = try await named(in: context, for: person) else { return noSuchBot() }
                let input = try await body(BotConfiguration.self, of: request, context: context)
                let changed = Added()
                if let refused = try await saving(
                    input, over: saved,
                    { bot in
                        try await space.changeBot(bot, by: person)
                        await changed.keep(bot)
                    })
                {
                    return refused
                }
                guard let bot = await changed.bot else { return noSuchBot() }
                return try publicAPIResponse(SpaceBot(bot, isMain: try await space.mainBot().id == bot.id))
            }
        }

        // A bot removed, as the person, who may configure its bots, asks: it's in none of its
        // conversations any more, and its key is let go.
        spaces.delete(":space/bots/:bot") { request, context in
            try await answering(request) { person in
                guard let (space, saved) = try await named(in: context, for: person) else { return noSuchBot() }
                try await space.removeBot(saved.id, by: person)
                if let key = saved.model.location.credentialReference { try? await credentials.remove(key) }
                return Response(status: .noContent)
            }
        }

        // A bot its space's main one from now on: it answers where no other is asked for.
        spaces.put(":space/bots/:bot/main") { request, context in
            try await answering(request) { person in
                guard let (space, saved) = try await named(in: context, for: person) else { return noSuchBot() }
                try await space.chooseMain(saved.id, by: person)
                return Response(status: .noContent)
            }
        }

        let channelSecrets = dependencies.channelSecrets

        /// The connection `context` names, of the space it names, as `person`, who may configure
        /// them, sees it.
        @Sendable func connection(in context: BasicWebSocketRequestContext, for person: TurgaiDomain.UserID)
            async throws -> (TurgaiDomain.SpaceID, Connection)?
        {
            guard let id = spaceID(in: context),
                let connection = context.parameters.get("connection").flatMap(ConnectionID.init)
            else { return nil }
            let space = try await Space.identified(by: id, on: system)
            guard let found = try await space.connections(for: person).first(where: { $0.id == connection }) else {
                return nil
            }
            return (id, found)
        }

        /// `connection` with `token` typed now, checked with its platform first: `save` saves it,
        /// and when that fails, the token saved before is put back.
        @Sendable func saving(
            _ connection: Connection, token typed: String?, _ save: () async throws -> Void
        ) async throws -> Response? {
            let id = connection.id.rawValue
            let token = typed?.trimmed().isEmpty == false ? typed?.trimmed() : nil
            if let token {
                do {
                    switch connection.platform {
                    case .telegram: try await TelegramAPIClient.live(token: token).validateToken()
                    }
                } catch {
                    return publicAPIErrorResponse(
                        status: .badRequest, code: "token_refused", message: "The platform refused this token.")
                }
            }
            let previous = token == nil ? nil : try await channelSecrets.token(for: id)
            do {
                if let token { try await channelSecrets.setToken(for: id, token: token) }
                try await save()
            } catch {
                if token != nil {
                    if let previous {
                        try? await channelSecrets.setToken(for: id, token: previous)
                    } else {
                        try? await channelSecrets.remove(for: id)
                    }
                }
                throw error
            }
            return nil
        }

        /// What `settings` set up, over `saved` when it changes one: none when its label isn't one.
        @Sendable func connection(_ settings: ConnectionSettings, over saved: Connection?) -> Connection? {
            guard let label = ConnectionLabel(settings.label) else { return nil }
            let platform: TurgaiDomain.ConnectionPlatform =
                switch settings.platform {
                case .telegram(let chatIDs): .telegram(TelegramAccess(chatIDs: chatIDs))
                }
            return Connection(
                id: saved?.id ?? ConnectionID(), label: label, enabled: settings.enabled, platform: platform)
        }

        // Its connections, as the person, who may configure them, sees them.
        spaces.get(":space/connections") { request, context in
            try await answering(request) { person in
                guard let id = spaceID(in: context) else { return noSuchSpace() }
                var listed: [SpaceConnection] = []
                let space = try await Space.identified(by: id, on: system)
                let scope = try await space.scope(of: person)
                for connection in try await space.connections(for: person) {
                    let status = try await CallChain.$current.withValue(.start(scope, in: nil)) {
                        try await ConnectionRun.of(connection.id, in: id, on: system).status
                    }
                    listed.append(
                        SpaceConnection(
                            connection, status: status,
                            hasToken: try await channelSecrets.hasToken(for: connection.id.rawValue)))
                }
                return try publicAPIResponse(listed)
            }
        }

        // A connection added: it runs once it's enabled, with its token.
        spaces.post(":space/connections") { request, context in
            try await answering(request) { person in
                guard let id = spaceID(in: context) else { return noSuchSpace() }
                let input = try await body(ConnectionSettings.self, of: request, context: context)
                guard let added = connection(input, over: nil) else { return invalidLabel() }
                if let refused = try await saving(
                    added, token: input.token,
                    {
                        try await Space.identified(by: id, on: system).addConnection(added, by: person)
                    })
                {
                    return refused
                }
                return Response(status: .created)
            }
        }

        // A connection as the settings say from now on, its saved token kept when none is typed: it
        // runs again as it is now.
        spaces.patch(":space/connections/:connection") { request, context in
            try await answering(request) { person in
                guard let (space, saved) = try await connection(in: context, for: person) else {
                    return noSuchConnection()
                }
                let input = try await body(ConnectionSettings.self, of: request, context: context)
                guard let changed = connection(input, over: saved) else { return invalidLabel() }
                if let refused = try await saving(
                    changed, token: input.token,
                    {
                        try await Space.identified(by: space, on: system).changeConnection(changed, by: person)
                    })
                {
                    return refused
                }
                return Response(status: .noContent)
            }
        }

        // A connection removed: it stops, and its token is let go.
        spaces.delete(":space/connections/:connection") { request, context in
            try await answering(request) { person in
                guard let (space, saved) = try await connection(in: context, for: person) else {
                    return noSuchConnection()
                }
                try await Space.identified(by: space, on: system).removeConnection(saved.id, by: person)
                try? await channelSecrets.remove(for: saved.id.rawValue)
                return Response(status: .noContent)
            }
        }

        spaces.get(":space/people") { request, context in
            try await answering(request) { person in
                guard let id = spaceID(in: context) else { return noSuchSpace() }
                let names = ParticipantNames(auth: auth, in: id, on: system)
                var people: [SpacePerson] = []
                for (person, groups) in try await Space.identified(by: id, on: system).people(for: person) {
                    people.append(
                        SpacePerson(
                            id: person.key, name: try await names.name(of: .person(person)),
                            groups: groups.map(\.rawValue).sorted()))
                }
                return try publicAPIResponse(people.sorted { $0.name < $1.name })
            }
        }

        spaces.get(":space/invites") { request, context in
            try await answering(request) { person in
                guard let id = spaceID(in: context) else { return noSuchSpace() }
                return try publicAPIResponse(
                    try await Space.identified(by: id, on: system).openInvites(for: person).map {
                        SpaceInviteListing(id: $0.id.rawValue.uuidString, expiresAt: $0.expiresAt)
                    })
            }
        }

        spaces.delete(":space/invites/:invite") { request, context in
            try await answering(request) { person in
                guard let id = spaceID(in: context),
                    let invite = context.parameters.get("invite").flatMap(UUID.init(uuidString:))
                else { return noSuchSpace() }
                try await Space.identified(by: id, on: system).takeBack(SpaceInviteID(rawValue: invite), by: person)
                return Response(status: .noContent)
            }
        }

        spaces.post(":space/join") { request, context in
            try await answering(request) { person in
                guard let id = spaceID(in: context) else { return noSuchSpace() }
                let input = try await body(JoinSpaceRequest.self, of: request, context: context)
                let space = try await Space.identified(by: id, on: system)
                try await space.join(with: SpaceInviteToken(input.token).hash, as: person)
                return try publicAPIResponse(try await summary(of: space, for: person))
            }
        }
    }

    /// A space's objects, as its people may read them: those made in it and its installed built-in
    /// ones, listed, and shared with everyone in it. Part of ``registerSpaces(on:dependencies:)``.
    private func registerSpaceObjects(
        on spaces: RouterGroup<BasicWebSocketRequestContext>, dependencies: TurgaiRouteDependencies
    ) {
        let auth = dependencies.auth
        let system = dependencies.system

        /// What `request`'s person asks of a space's objects, refused when no one signed in, and
        /// said back as the API says it.
        @Sendable func answering(
            _ request: Request, _ answer: (TurgaiDomain.UserID) async throws -> Response
        ) async throws -> Response {
            guard let person = await signedInPerson(from: request, auth: auth) else { return signInRequired() }
            do {
                return try await answer(person)
            } catch let refusal as SpaceRefusal {
                return spaceRefused(refusal)
            }
        }

        // Its objects the person may read: those made in it, and the built-in ones.
        spaces.get(":space/objects") { request, context in
            try await answering(request) { person in
                guard let id = spaceID(in: context) else { return noSuchSpace() }
                // The space lists what's its own, as the person may see it.
                let entries = try await Space.identified(by: id, on: system).objects(for: person)
                return try publicAPIResponse(entries.map(ObjectListing.init))
            }
        }

        // One of its objects' card, by its handle as listed: what it is, its YAML and its Swift. Only
        // for one the person may read.
        spaces.get(":space/objects/:object/card") { request, context in
            try await answering(request) { person in
                guard let id = spaceID(in: context) else { return noSuchSpace() }
                guard let handle = context.parameters.get("object") else { return noSuchObject() }
                let space = try await Space.identified(by: id, on: system)
                let scope = try await space.scope(of: person)
                // Asked on the person's behalf, as the list is: one they may not read isn't found.
                let card = try await CallChain.$current.withValue(.start(scope, in: nil)) { () async throws -> Card? in
                    try await ObjectSession(in: id, actorSystem: system).card(named: handle)
                }
                guard case .markdown(let markdown)? = card else { return noSuchObject() }
                return try publicAPIResponse(ObjectCard(markdown: markdown))
            }
        }

        // One of its objects shared with everyone in it, or that taken back: only one who may change
        // it does.
        spaces.post(":space/objects/:object/share") { request, context in
            try await answering(request) { person in
                guard let id = spaceID(in: context), let object = context.parameters.get("object") else {
                    return noSuchSpace()
                }
                let sharing = try await body(ObjectSharingRequest.self, of: request, context: context)
                let level: AccessLevel? =
                    switch sharing.everyone {
                    case .read: .read
                    case .write: .write
                    case .none: nil
                    }
                let space = try await Space.identified(by: id, on: system)
                let scope = try await space.scope(of: person)
                // The object, by its id: its space is asked as it's called.
                let made = try await DynamicObject.identified(by: ObjectIdentity(rawValue: object), in: id, on: system)
                do {
                    try await CallChain.$current.withValue(.start(scope, in: nil)) {
                        try await made.share(with: .everyone, level)
                    }
                } catch is NotAllowed {
                    return Response(status: .forbidden)
                }
                return Response(status: .noContent)
            }
        }
    }

    /// A conversation's messages, through the API: reading them, and sending one.
    private func registerMessages(
        on messages: RouterGroup<BasicWebSocketRequestContext>, dependencies: TurgaiRouteDependencies
    ) {
        messages.get { request, context in
            guard let owner = await chatOwner(from: request, auth: dependencies.auth) else { return signInRequired() }
            guard
                let conversation = try await apiConversation(
                    context.parameters.get("id"), in: context.parameters.get("space"), readBy: owner.person,
                    dependencies: dependencies)
            else { return conversationNotFound() }
            let history = try await conversation.reached(on: dependencies.system).history(
                of: conversation.domainID, for: owner.person)
            return try publicAPIResponse(try await publicAPIMessages(history, names: conversation.names))
        }

        messages.post { request, context in
            guard let owner = await chatOwner(from: request, auth: dependencies.auth) else { return signInRequired() }
            guard
                let conversation = try await apiConversation(
                    context.parameters.get("id"), in: context.parameters.get("space"), readBy: owner.person,
                    dependencies: dependencies)
            else { return conversationNotFound() }
            let input = try await body(TurgaiModels.SendMessageRequest.self, of: request, context: context)
            let text = input.text.trimmed()
            guard !text.isEmpty else {
                return publicAPIErrorResponse(
                    status: .badRequest,
                    code: "empty_message",
                    message: "A message must contain text."
                )
            }
            let addressed = input.to.compactMap(Participant.init)
            guard addressed.count == input.to.count else { return noSuchParticipant() }
            let to = Set(addressed)
            do {
                let event = try await send(
                    input: input,
                    text: text,
                    conversation: conversation,
                    as: owner.person,
                    to: to,
                    dependencies: dependencies,
                    names: conversation.names
                )
                var response = try publicAPIResponse(event)
                if case .guest(_, let token) = owner { response.setCookie(TurgaiWebSupport.guestCookie(token)) }
                return response
            } catch {
                return publicAPIErrorResponse(
                    status: .conflict,
                    code: "message_rejected",
                    message: "The message could not be accepted."
                )
            }
        }
    }
}

private struct APIConversation: Sendable {
    /// The space it's one of, which it's reached through.
    let space: TurgaiDomain.SpaceID
    let domainID: TurgaiDomain.ConversationID
    /// Who's in it.
    let outline: ConversationOutline
    /// The bot that answers in it, as its space has it now: none once it's left.
    let bot: TurgaiDomain.Bot?
    /// What its participants are called.
    let names: ParticipantNames

    /// What the API calls it: the id it was given as it started.
    var publicID: TurgaiModels.ConversationID { .init(rawValue: domainID.externalAddress.rawValue) }

    var info: TurgaiModels.Conversation {
        .init(
            id: publicID, botID: bot.map { .init(rawValue: $0.id.role) }, spaceID: space.api,
            people: outline.participants.count { if case .person = $0 { true } else { false } })
    }

    /// Its space, which it's reached through.
    func reached(on system: ClusterSystem) async throws -> Space {
        try await Space.identified(by: space, on: system)
    }
}

/// The conversation the API calls `id` in the space it calls `space`, as `person` reads it: none
/// when there's no such conversation, or they're not one of its people, which the API doesn't tell
/// apart.
private func apiConversation(
    _ id: String?, in space: String?, readBy person: TurgaiDomain.UserID, dependencies: TurgaiRouteDependencies
) async throws -> APIConversation? {
    guard let id, let minted = UUID(uuidString: id),
        let spaceID = space.flatMap({ TurgaiDomain.SpaceID(TurgaiModels.SpaceID(rawValue: $0)) })
    else { return nil }
    let domainID = TurgaiDomain.ConversationID(channel: turgaiChannel, externalAddress: .init(minted.uuidString))
    let reached = try await Space.identified(by: spaceID, on: dependencies.system)
    let outline: ConversationOutline
    do {
        outline = try await reached.reading(domainID, by: person)
    } catch is ConversationRefusal {
        return nil
    } catch is SpaceRefusal {
        return nil
    }
    return APIConversation(
        space: spaceID, domainID: domainID, outline: outline, bot: try await reached.answeringBot(of: domainID),
        names: ParticipantNames(auth: dependencies.auth, in: spaceID, on: dependencies.system))
}

/// The conversation an app's connection has open, if it has one.
/// The topics a connection has joined, each with how it's left.
private actor JoinedTopics {
    private var leaving: [TurgaiModels.ChatTopic: @Sendable () async -> Void] = [:]

    /// `topic` joined by `follow`, which gives how it's left: once, however often it's joined.
    func join(
        _ topic: TurgaiModels.ChatTopic, by follow: () async throws -> @Sendable () async -> Void
    ) async throws {
        guard leaving[topic] == nil else { return }
        leaving[topic] = try await follow()
    }

    func leave(_ topic: TurgaiModels.ChatTopic) async {
        await leaving.removeValue(forKey: topic)?()
    }

    func leaveAll() async {
        for leave in leaving.values { await leave() }
        leaving = [:]
    }
}

/// What a connection follows, its topic read: a space's tasks by the space's id.
private enum Following {
    case memory
    case tasks(TurgaiDomain.SpaceID)
    case objects(TurgaiDomain.SpaceID)

    /// `topic`, read: none when the space it names isn't one.
    init?(_ topic: TurgaiModels.ChatTopic) {
        switch topic {
        case .memory:
            self = .memory
        case .tasks(let space):
            guard let id = TurgaiDomain.SpaceID(space) else { return nil }
            self = .tasks(id)
        case .objects(let space):
            guard let id = TurgaiDomain.SpaceID(space) else { return nil }
            self = .objects(id)
        }
    }
}

/// `person` told about `following` on the connection `writer` writes to, as it changes, until the
/// returned function is called.
private func follow(
    _ following: Following, for person: TurgaiDomain.UserID, writer: PublicChatSocketWriter,
    dependencies: TurgaiRouteDependencies
) async throws -> @Sendable () async -> Void {
    let system = dependencies.system
    switch following {
    case .objects(let space):
        // Its space hands its objects to someone in it, who follows that they changed; what they
        // are as it's joined, the app lists itself.
        let reached = try await Space.identified(by: space, on: system)
        let chain = CallChain.start(try await reached.scope(of: person), in: nil)
        let changes = try await CallChain.$current.withValue(chain) {
            try await ObjectSession(in: space, actorSystem: system, builtIns: []).changes()
        }
        let forwarding = Task {
            for await _ in changes { try? await writer.write(.init(payload: .objectsChanged)) }
        }
        // Left, its subscription ends, and nothing more is told.
        return {
            await changes.cancel()
            forwarding.cancel()
        }
    case .memory:
        let changes = try await system.singleton.proxy(MemoryNotices.self, name: MemoryNotices.singletonName)
            .subscription(for: person)
        let forwarding = Task {
            for await _ in changes { try? await writer.write(.init(payload: .memoryChanged)) }
        }
        return {
            await changes.cancel()
            forwarding.cancel()
        }
    case .tasks(let space):
        // What the tasks are now goes first; each change follows it, in order.
        let id = space.api
        let reached = try await Space.identified(by: space, on: system)
        let scope = try await reached.scope(of: person)
        let chain = CallChain.start(scope, in: nil)
        // A chat's task is seen by whoever is in the chat; an object's by whoever may see the
        // object, as it's shared now; and all by whoever may see the space's tasks.
        let sees: @Sendable (KeptTask) async -> Bool = { task in
            if scope.permissions.tasks != nil { return true }
            switch task.of {
            case .chat(let chat, _, _): return (try? await reached.reading(chat, by: person)) != nil
            case .object(let object, _):
                // Whoever may read the object: asked of the object itself, by its id.
                let read = try? await CallChain.$current.withValue(chain) {
                    try await DynamicObject.identified(by: object, in: space, on: system).access
                }
                return read != nil
            }
        }
        // Following first, so no change between this and what's read now is missed. Followed for
        // the person, as the space said they may when they joined the topic.
        let changes = try await CallChain.$current.withValue(chain) {
            try await reached.tasks(for: person).subscription()
        }
        // What's kept now: its objects' schedules and timers, and its chats'.
        let workflows = system.workflows
        let decoder = JSONDecoder()
        var tasks: [KeptTask] = []
        for schedule in try await workflows.listSchedules(workflow: ObjectScheduleWorkflow.self) {
            guard let firing = try? decoder.decode(ObjectFiring.self, from: schedule.inputData), firing.space == space
            else { continue }
            tasks.append(
                KeptTask(
                    id: .schedule(schedule.id), of: .object(firing.object, field: firing.property), due: firing.due,
                    paused: schedule.paused))
        }
        for timer in try await workflows.listWorkflows(workflow: ObjectTimerWorkflow.self) {
            guard case .running = timer.status, let data = timer.inputData,
                let firing = try? decoder.decode(ObjectFiring.self, from: data), firing.space == space
            else { continue }
            tasks.append(
                KeptTask(
                    id: .timer(timer.id), of: .object(firing.object, field: firing.property), due: firing.due,
                    paused: false))
        }
        for schedule in try await workflows.listSchedules(workflow: ScheduleWorkflow.self) {
            guard let made = try? decoder.decode(ChatSchedule.self, from: schedule.inputData), made.space == space
            else { continue }
            tasks.append(KeptTask(made, id: schedule.id, paused: schedule.paused))
        }
        for timer in try await workflows.listWorkflows(workflow: TimerWorkflow.self) {
            guard case .running = timer.status, let data = timer.inputData,
                let made = try? decoder.decode(ChatTimer.self, from: data), made.space == space
            else { continue }
            tasks.append(KeptTask(made, id: timer.id))
        }
        var seen: [KeptTask] = []
        for task in tasks where await sees(task) { seen.append(task) }
        try? await writer.write(.init(payload: .tasks(space: id, tasks: seen.map(TaskListing.init))))
        let forwarding = CallChain.$current.withValue(chain) {
            Task {
                for await notice in changes {
                    switch notice {
                    case .kept(let task):
                        guard await sees(task) else { continue }
                        try? await writer.write(.init(payload: .taskKept(space: id, task: TaskListing(task))))
                    case .ended(let task):
                        try? await writer.write(.init(payload: .taskEnded(space: id, id: task.listed)))
                    }
                }
            }
        }
        // Left, its subscription ends, and nothing more is told.
        return {
            await CallChain.$current.withValue(chain) { await changes.cancel() }
            forwarding.cancel()
        }
    }
}

/// The answer to `ask`, asked by `person` on the connection `writer` writes to: a topic joined or
/// left, what's remembered about them, forgetting it, or remembering on or off.
private func answer(
    _ ask: TurgaiModels.ChatAsk, for person: TurgaiDomain.UserID, topics: JoinedTopics,
    writer: PublicChatSocketWriter, dependencies: TurgaiRouteDependencies
) async -> TurgaiModels.ChatReply {
    let system = dependencies.system
    do {
        switch ask {
        case .join(let topic):
            guard let following = Following(topic) else { return .failed(notASpace) }
            try await topics.join(topic) {
                try await follow(following, for: person, writer: writer, dependencies: dependencies)
            }
            return .ok
        case .leave(let topic):
            await topics.leave(topic)
            return .ok
        case .memory:
            return .memory(try await memory(of: person, on: system))
        case .forgetMemory:
            _ = try await User.identified(by: person, on: system).forgetMemory()
            return .ok
        case .setRemembering(let remembering):
            try await User.identified(by: person, on: system).setRemembering(Remembering(remembering))
            return .ok
        case .archiveSpace(let space):
            guard let id = TurgaiDomain.SpaceID(space) else { return .failed(notASpace) }
            try await Space.identified(by: id, on: system).archive(by: person)
            return .ok
        case .unarchiveSpace(let space):
            guard let id = TurgaiDomain.SpaceID(space) else { return .failed(notASpace) }
            try await Space.identified(by: id, on: system).unarchive(by: person)
            return .ok
        case .leaveConversation(let conversation, let space):
            guard let space = TurgaiDomain.SpaceID(space) else { return .failed(notASpace) }
            try await Space.identified(by: space, on: system).leave(domainID(of: conversation), as: person)
            return .ok
        case .deleteConversation(let conversation, let space):
            guard let space = TurgaiDomain.SpaceID(space) else { return .failed(notASpace) }
            try await Space.identified(by: space, on: system).delete(domainID(of: conversation), by: person)
            return .ok
        case .stopConversation(let conversation, let space):
            guard let space = TurgaiDomain.SpaceID(space) else { return .failed(notASpace) }
            try await Space.identified(by: space, on: system).stop(domainID(of: conversation), by: person)
            return .ok
        case .changeSchedule(let chat, let space, let name, let change):
            guard let chat = TurgaiDomain.ConversationID(stableKey: chat.rawValue) else { return .failed(notAChat) }
            guard let space = TurgaiDomain.SpaceID(space) else { return .failed(notASpace) }
            // On their behalf in the chat, as they are in it: refused unless they made it, or may
            // change the space's tasks.
            let reached = try await Space.identified(by: space, on: system)
            _ = try await reached.reading(chat, by: person)
            let scope = try await reached.scope(of: person)
            try await CallChain.$current.withValue(.start(scope, in: chat)) {
                let scheduler = try await Scheduler.of(space, on: system)
                switch InChatCommand.TaskChange(change) {
                case .pause: _ = try await scheduler.pause(name: name)
                case .resume: _ = try await scheduler.resume(name: name)
                case .cancel: _ = try await scheduler.cancel(name: name)
                }
            }
            return .ok
        case .cancelReminder(let chat, let space, let name):
            guard let chat = TurgaiDomain.ConversationID(stableKey: chat.rawValue) else { return .failed(notAChat) }
            guard let space = TurgaiDomain.SpaceID(space) else { return .failed(notASpace) }
            // On their behalf in the chat, as they are in it: refused unless they set it, or may
            // change the space's tasks.
            let reached = try await Space.identified(by: space, on: system)
            _ = try await reached.reading(chat, by: person)
            let scope = try await reached.scope(of: person)
            try await CallChain.$current.withValue(.start(scope, in: chat)) {
                _ = try await Timers.of(space, on: system).cancel(name: name)
            }
            return .ok
        }
    } catch let refusal as DueInChatError {
        return .failed(TurgaiModels.ChatError(code: "refused", message: refusal.description))
    } catch let refusal as SpaceRefusal {
        return .failed(TurgaiModels.ChatError(code: "refused", message: refusal.description))
    } catch let refusal as ConversationRefusal {
        return .failed(TurgaiModels.ChatError(code: "refused", message: refusal.description))
    } catch {
        return .failed(TurgaiModels.ChatError(code: "push_failed", message: "That didn't work. Try again."))
    }
}

/// What's remembered about `person`, and whether they're remembered, as the API gives it.
private func memory(of person: TurgaiDomain.UserID, on system: ClusterSystem) async throws -> MemorySummary {
    let user = try await User.identified(by: person, on: system)
    return MemorySummary(try await user.remembered(), remembering: try await user.currentRemembering())
}

/// What a push names no space by.
private let notASpace = TurgaiModels.ChatError(code: "not_a_space", message: "There's no such space.")

/// What a push names no chat by.
private let notAChat = TurgaiModels.ChatError(code: "not_a_chat", message: "There's no such chat.")

extension InChatCommand.TaskChange {
    /// `change`, as the app asks for it.
    fileprivate init(_ change: ScheduleChange) {
        self =
            switch change {
            case .pause: .pause
            case .resume: .resume
            case .cancel: .cancel
            }
    }
}

/// The conversation an app calls `id`, as Turgai's apps' conversations are kept.
private func domainID(of id: TurgaiModels.ConversationID) -> TurgaiDomain.ConversationID {
    TurgaiDomain.ConversationID(channel: turgaiChannel, externalAddress: .init(id.rawValue))
}

private actor ShownConversation {
    private(set) var conversation: APIConversation?

    func show(_ conversation: APIConversation) {
        self.conversation = conversation
    }
}

/// `session` attached to `conversation` for `person`, so its live events come: whether it was.
private func open(
    _ conversation: APIConversation, for person: TurgaiDomain.UserID, on session: LiveSession
) async throws -> Bool {
    let receipt = ConversationInputReceipt()
    await session.input.send(
        ConversationInputDelivery(
            in: conversation.space, input: .connect(conversation.domainID, for: person), receipt: receipt))
    return await receipt.wait()
}

/// What an app's connection is sent as it opens `conversation` for `person`: that it's open, what's
/// been said in it, and the agent's past turns.
private func writeOpened(
    _ conversation: APIConversation, for person: TurgaiDomain.UserID, on writer: PublicChatSocketWriter,
    names: ParticipantNames, dependencies: TurgaiRouteDependencies
) async throws {
    let space = try await conversation.reached(on: dependencies.system)
    let history = try await publicAPIMessages(
        try await space.history(of: conversation.domainID, for: person), names: names)
    let status = try await space.status(of: conversation.domainID, for: person)
    try await writer.write(
        .init(
            payload: .ready(
                conversationID: conversation.publicID, botID: conversation.bot.map { .init(rawValue: $0.id.role) },
                status: publicConversationStatus(status), you: person.key)))
    try await writer.write(.init(payload: .history(conversationID: conversation.publicID, messages: history)))
    // The agent's turns, step by step; the chat works without them, and says why they're missing.
    let turns: [ConversationTurn]
    do {
        turns = try await agentTurns(in: conversation, of: space, askedBy: person, journal: dependencies.journal)
    } catch {
        try await writer.write(
            publicAPIErrorEvent(
                conversationID: conversation.publicID, code: "turns_unavailable",
                message: "Couldn't read what the agent did: \(error)"))
        return
    }
    try await writer.write(
        .init(payload: .turns(conversationID: conversation.publicID, turns: turns.map(TurnRecord.init))))
}

/// `request`, said by `person` in `conversation` through `session`: what's wrong with it, or that
/// it was refused, written back.
private func say(
    _ request: TurgaiModels.SendMessageRequest, in conversation: APIConversation, as person: TurgaiDomain.UserID,
    on session: LiveSession, writer: PublicChatSocketWriter
) async throws {
    let text = request.text.trimmed()
    guard !text.isEmpty else {
        try await writer.write(
            publicAPIErrorEvent(
                conversationID: conversation.publicID, code: "empty_message", message: "A message must contain text."))
        return
    }
    let to = request.to.compactMap(Participant.init)
    guard to.count == request.to.count else {
        try await writer.write(
            publicAPIErrorEvent(
                conversationID: conversation.publicID, code: "invalid_participant",
                message: "No person or bot has that id."))
        return
    }
    let receipt = ConversationInputReceipt()
    await session.input.send(
        ConversationInputDelivery(
            in: conversation.space,
            input: .message(
                InboundMessage(
                    id: .init(rawValue: request.id.rawValue),
                    conversationID: conversation.domainID,
                    participantID: ParticipantID(channel: turgaiChannel, rawValue: person.key),
                    userID: person,
                    text: text,
                    receivedAt: Date(),
                    to: Set(to)
                ),
                turnID: .init()
            ),
            receipt: receipt))
    guard await receipt.wait() else {
        try await writer.write(
            publicAPIErrorEvent(
                conversationID: conversation.publicID, code: "message_rejected",
                message: "The message could not be accepted."))
        return
    }
}

/// What a conversation refused, as the API says it: one the person isn't in is one that isn't
/// there.
private func conversationRefused(_ refusal: ConversationRefusal) -> Response {
    switch refusal {
    case .notStarted, .notInIt: conversationNotFound()
    case .guestsStayOut:
        publicAPIErrorResponse(status: .forbidden, code: "guests_stay_out", message: refusal.description)
    case .alreadyStarted:
        publicAPIErrorResponse(status: .conflict, code: "already_started", message: refusal.description)
    case .oneBotForNow:
        publicAPIErrorResponse(status: .conflict, code: "one_bot_for_now", message: refusal.description)
    case .addresseeNotInIt:
        publicAPIErrorResponse(status: .badRequest, code: "addressee_not_in_it", message: refusal.description)
    case .deleted: conversationNotFound()
    case .othersAreInIt:
        publicAPIErrorResponse(status: .forbidden, code: "others_are_in_it", message: refusal.description)
    case .spaceArchived:
        publicAPIErrorResponse(status: .conflict, code: "space_archived", message: refusal.description)
    }
}

/// The agents' past turns in `conversation` of `space`, step by step, as `person` asks for them:
/// read from each agent's journal, under the conversation's ids.
private func agentTurns(
    in conversation: APIConversation, of space: Space, askedBy person: TurgaiDomain.UserID, journal: any EventStore
) async throws -> [ConversationTurn] {
    let agentTurns = try await space.agentTurns(of: conversation.domainID, for: person)
    var turns: [ConversationTurn] = []
    for bot in agentTurns.bots {
        let agentID = HailAgentAdapter.agentID(for: conversation.domainID, in: conversation.space, role: bot.role)
        let events: [AgentEvent] = try await journal.eventsFor(id: agentID.rawValue)
        turns += try ConversationTurns.turns(from: events, links: agentTurns.links)
    }
    return turns.sorted { $0.startedAt < $1.startedAt }
}

/// The answer for a participant the API can't name.
private func noSuchConnection() -> Response {
    publicAPIErrorResponse(
        status: .notFound, code: "connection_not_found", message: "The space has no such connection.")
}

private func invalidLabel() -> Response {
    publicAPIErrorResponse(
        status: .badRequest, code: "invalid_label",
        message: "A connection's label is some words, at most \(ConnectionLabel.maximumLength) letters.")
}

private func noSuchBot() -> Response {
    publicAPIErrorResponse(status: .notFound, code: "bot_not_found", message: "The space has no such bot.")
}

private func noSuchParticipant() -> Response {
    publicAPIErrorResponse(status: .badRequest, code: "invalid_participant", message: "No person or bot has that id.")
}

extension Participant {
    /// The participant `reference` names: none when it names no person.
    fileprivate init?(_ reference: ParticipantRef) {
        switch reference.kind {
        case .person:
            guard let person = try? TurgaiDomain.UserID(key: reference.id) else { return nil }
            self = .person(person)
        case .agent:
            guard let bot = TurgaiDomain.BotID(reference.id) else { return nil }
            self = .bot(bot)
        }
    }
}

extension ParticipantRef {
    /// `participant` as the API refers to them.
    fileprivate init(_ participant: Participant) {
        switch participant {
        case .person(let person): self.init(kind: .person, id: person.key)
        case .bot(let bot): self.init(kind: .agent, id: bot.role)
        }
    }
}

/// What participants are called, as the API shows them, each looked up once: an account by its
/// username, a bot by its name in `space`, a Telegram person and a guest by what they are.
private actor ParticipantNames {
    private let auth: TurgaiAuth
    /// The space whose bots are named, and the cluster it's reached on: none where no bot is.
    private let space: (id: TurgaiDomain.SpaceID, system: ClusterSystem)?
    private var known: [Participant: String] = [:]

    init(auth: TurgaiAuth, in space: TurgaiDomain.SpaceID, on system: ClusterSystem) {
        self.auth = auth
        self.space = (space, system)
    }

    /// Names for where no bot is: people only.
    init(auth: TurgaiAuth, in _: Never?) {
        self.auth = auth
        self.space = nil
    }

    /// `participant` as the API names them.
    func summary(of participant: Participant) async throws -> ParticipantSummary {
        ParticipantSummary(participant, name: try await name(of: participant))
    }

    func name(of participant: Participant) async throws -> String {
        if let name = known[participant] { return name }
        let name =
            switch participant {
            case .person(.account(let id)): try await auth.accounts().first { $0.id == id }?.username ?? "Someone"
            case .person(.telegram(let id)): "Telegram user \(id)"
            case .person(.guest): "Guest"
            case .bot(let bot):
                if let space {
                    try await Space.identified(by: space.id, on: space.system).bot(bot)?.name.rawValue ?? "Bot"
                } else {
                    "Bot"
                }
            }
        known[participant] = name
        return name
    }
}

extension TurgaiModels.Message {
    /// It as `viewer` is shown it in the web chat: with its author only when that's someone else,
    /// a person.
    fileprivate func shown(to viewer: TurgaiDomain.UserID) -> Self {
        guard let author, author.kind == .person, author.id != viewer.key else {
            return Self(id: id, role: role, text: text, at: at)
        }
        return self
    }
}

extension ParticipantSummary {
    /// `participant` as the API names them, called `name`.
    fileprivate init(_ participant: Participant, name: String) {
        switch participant {
        case .person(let person): self.init(kind: .person, id: person.key, name: name)
        case .bot(let bot): self.init(kind: .agent, id: bot.role, name: name)
        }
    }
}

/// The answer for a conversation the person can't read, or that isn't there.
private func conversationNotFound() -> Response {
    publicAPIErrorResponse(
        status: .notFound, code: "conversation_not_found", message: "The conversation does not exist.")
}

/// The person a request is from: its signed-in account's.
private func signedInPerson(from request: Request, auth: TurgaiAuth) async -> TurgaiDomain.UserID? {
    await TurgaiWebSupport.authenticatedAccount(from: request, auth: auth).map { .account($0.id) }
}

/// The space a path names.
private func spaceID(in context: BasicWebSocketRequestContext) -> TurgaiDomain.SpaceID? {
    context.parameters.get("space").flatMap { TurgaiDomain.SpaceID(TurgaiModels.SpaceID(rawValue: $0)) }
}

private func noSuchObject() -> Response {
    publicAPIErrorResponse(status: .notFound, code: "no_such_object", message: "No object like that here.")
}

private func noSuchSpace() -> Response {
    publicAPIErrorResponse(status: .notFound, code: "no_such_space", message: "No space like that.")
}

private func nameRequired() -> Response {
    publicAPIErrorResponse(
        status: .badRequest, code: "invalid_name",
        message: "A space's name is some words, at most \(SpaceName.maximumLength) letters.")
}

/// What a space refused, as the API says it.
private func spaceRefused(_ refusal: SpaceRefusal) -> Response {
    let (status, code): (HTTPResponse.Status, String) =
        switch refusal {
        case .alreadyMade: (.conflict, "already_made")
        case .guestsStayOut: (.forbidden, "guests_stay_out")
        case .notMadeYet: (.notFound, "not_made_yet")
        case .notAllowed: (.forbidden, "not_allowed")
        case .noSuchGroup: (.notFound, "no_such_group")
        case .groupExists: (.conflict, "group_exists")
        case .membersGroupStays: (.conflict, "members_group_stays")
        case .guestsGroupStays: (.conflict, "guests_group_stays")
        case .someoneIsOnlyIn: (.conflict, "someone_is_only_in_it")
        case .anAdmin: (.conflict, "an_admin")
        case .notInIt: (.notFound, "not_in_it")
        case .lastAdmin: (.conflict, "last_admin")
        case .inviteDoesNotWork: (.conflict, "invite_does_not_work")
        case .noSuchBot: (.notFound, "bot_not_found")
        case .botExists: (.conflict, "bot_exists")
        case .mainBotStays: (.conflict, "main_bot_stays")
        case .noSuchConnection: (.notFound, "connection_not_found")
        case .connectionExists: (.conflict, "connection_exists")
        case .archived: (.conflict, "archived")
        }
    return publicAPIErrorResponse(status: status, code: code, message: refusal.description)
}

extension TurgaiDomain.SpaceID {
    /// The space the API's `id` names: none when it names none.
    fileprivate init?(_ id: TurgaiModels.SpaceID) {
        guard let uuid = UUID(uuidString: id.rawValue) else { return nil }
        self.init(rawValue: uuid)
    }

    /// What the API calls it.
    fileprivate var api: TurgaiModels.SpaceID { TurgaiModels.SpaceID(rawValue: rawValue.uuidString) }
}

extension SpaceSummary {
    /// `listing`, as the API gives it.
    fileprivate init(_ listing: SpaceListing) {
        self.init(
            id: listing.id.api, name: listing.name.rawValue,
            permissions: SpacePermissions(listing.permissions),
            status: listing.status == .archived ? .archived : .active)
    }
}

extension SpaceConnection {
    /// `connection` with its run's `status`, as the API gives it: its token only as whether it has
    /// one.
    fileprivate init(_ connection: Connection, status: ConnectionStatus, hasToken: Bool) {
        let platform: TurgaiModels.ConnectionPlatform =
            switch connection.platform {
            case .telegram(let access): .telegram(chatIDs: access.chatIDs)
            }
        self.init(
            id: connection.id.description, label: connection.label.rawValue, enabled: connection.enabled,
            platform: platform, hasToken: hasToken, running: status.running, stopped: status.stopped?.description)
    }
}

/// The bot a save made, once it's saved.
private actor Added {
    private(set) var bot: TurgaiDomain.Bot?

    func keep(_ bot: TurgaiDomain.Bot) {
        self.bot = bot
    }
}

extension SpaceBot {
    /// `bot`, its space's main one or not, as the API gives it: its key only as whether it has one.
    fileprivate init(_ bot: TurgaiDomain.Bot, isMain: Bool) {
        let configuration = bot.model.location
        let address: String?
        let window: Int?
        if case .server(let server) = configuration {
            address = server.address.description
            window = if case .chosen(let chosen) = server.context { chosen.tokens } else { nil }
        } else {
            (address, window) = (nil, nil)
        }
        self.init(
            id: .init(rawValue: bot.id.role), name: bot.name.rawValue, instructions: bot.instructions,
            provider: ModelProvider(rawValue: configuration.provider.name) ?? .ollama, address: address,
            hasKey: configuration.credentialReference != nil, model: bot.model.name.rawValue, contextWindow: window,
            isMain: isMain)
    }
}

extension SpacePermissions {
    /// `permissions`, as the API gives them.
    fileprivate init(_ permissions: Permissions) {
        self.init(
            people: permissions.people.map { $0 == .manage ? .manage : .see },
            bots: permissions.bots.map { $0 == .configure ? .configure : .use },
            requests: permissions.requests.map { $0 == .runAny ? .runAny : .answer },
            tasks: permissions.tasks.map { $0 == .manage ? .manage : .see },
            connections: permissions.connections, deleteConversations: permissions.deleteConversations,
            configureSpace: permissions.configureSpace)
    }
}

extension MemorySummary {
    /// What's `remembered`, a line for each relation, and whether its person is remembered, as the
    /// API gives them.
    fileprivate init(_ remembered: Remembered, remembering: TurgaiMemory.Remembering) {
        self.init(
            nodes: remembered.lines.map { Node(name: $0.relation.words, said: $0.said, children: []) },
            remembering: Remembering(remembering))
    }
}

extension MemorySummary.Remembering {
    /// `remembering`, as the API gives it.
    fileprivate init(_ remembering: TurgaiMemory.Remembering) {
        switch remembering {
        case .on: self = .on
        case .off: self = .off
        }
    }
}

extension TurgaiMemory.Remembering {
    /// `remembering`, as the API gives it.
    fileprivate init(_ remembering: MemorySummary.Remembering) {
        switch remembering {
        case .on: self = .on
        case .off: self = .off
        }
    }
}

extension SpaceInvite {
    /// When it stops working: none when it works until it's used.
    fileprivate var expiresAt: Date? {
        if case .until(let end) = lifetime { end } else { nil }
    }
}

/// The answer to a request that needs a person, and has none.
private func signInRequired() -> Response {
    publicAPIErrorResponse(status: .unauthorized, code: "sign_in_required", message: "Sign in first.")
}

extension LinkedPerson {
    /// `person` as the API names them: none for a guest, whom no one links.
    fileprivate init?(_ person: TurgaiDomain.UserID) {
        switch person {
        case .account: self.init(id: person.key, kind: .account, telegramUserID: nil)
        case .telegram(let id): self.init(id: person.key, kind: .telegram, telegramUserID: id)
        case .guest: return nil
        }
    }
}

private enum ChatOwner: Sendable {
    case account(UUID)
    /// A guest no one signed in as, by the token they come back with.
    case guest(TurgaiDomain.UserID, token: String)

    /// Who writes for it: the signed-in account's person, or the guest.
    var person: TurgaiDomain.UserID {
        switch self {
        case .account(let id): .account(id)
        case .guest(let guest, _): guest
        }
    }
}

/// Who a request is from: its signed-in account, or the guest its cookie says. None when it's
/// neither: becoming a guest is asked for on its own.
private func chatOwner(from request: Request, auth: TurgaiAuth) async -> ChatOwner? {
    if let account = await TurgaiWebSupport.authenticatedAccount(from: request, auth: auth) {
        return .account(account.id)
    }
    if let token = request.cookies[TurgaiWebSupport.guestCookieName]?.value, let guest = await auth.guest(from: token) {
        return .guest(guest, token: token)
    }
    return nil
}

/// `history`, as the API shows it, each message with its author.
private func publicAPIMessages(
    _ history: [ConversationHistoryEntry], names: ParticipantNames
) async throws -> [TurgaiModels.Message] {
    var messages: [TurgaiModels.Message] = []
    for entry in history {
        let value = entry.id.split(separator: ":").last.map(String.init) ?? entry.id
        let author: ParticipantSummary? =
            if let author = entry.author { try await names.summary(of: author) } else { nil }
        messages.append(
            .init(
                id: .init(rawValue: UUID(uuidString: value) ?? UUID()),
                role: entry.role == .user ? .user : .assistant,
                text: entry.text,
                author: author,
                to: entry.to.map(ParticipantRef.init),
                at: entry.at
            ))
    }
    return messages
}

/// Who said what `event` carries, as the API names them: a person's message's author, or the agent
/// that answers for what it says; none for the rest.
private func author(
    of event: OutboundEvent, answeredBy bot: TurgaiDomain.BotID?, names: ParticipantNames
) async throws -> ParticipantSummary? {
    switch event {
    case .reply(.userMessage(_, _, _, _, let person, _, _)): try await names.summary(of: .person(person))
    case .reply(.partial), .reply(.finished): if let bot { try await names.summary(of: .bot(bot)) } else { nil }
    default: nil
    }
}

private func publicAPIResponse<T: Encodable>(
    _ value: T,
    status: HTTPResponse.Status = .ok
) throws -> Response {
    Response(
        status: status,
        headers: [.contentType: "application/json"],
        body: .init(byteBuffer: ByteBuffer(data: try JSONEncoder().encode(value)))
    )
}

private func publicAPIUnauthorizedResponse() -> Response {
    Response(status: .unauthorized)
}

private func publicAPIErrorResponse(
    status: HTTPResponse.Status,
    code: String,
    message: String
) -> Response {
    (try? publicAPIResponse(
        TurgaiModels.ChatError(code: code, message: message),
        status: status
    )) ?? Response(status: status)
}

/// A request's body the API can't read: answered with 400, and what's wrong with it.
private struct UnreadableBody: HTTPResponseError {
    let reason: String

    var status: HTTPResponse.Status { .badRequest }

    init(_ error: any Error) {
        func path(_ context: DecodingError.Context) -> String {
            context.codingPath.map(\.stringValue).joined(separator: ".")
        }
        reason =
            switch error {
            case DecodingError.keyNotFound(let key, let context):
                "\((context.codingPath + [key]).map(\.stringValue).joined(separator: ".")) is missing."
            case DecodingError.valueNotFound(_, let context) where !context.codingPath.isEmpty:
                "\(path(context)) is missing."
            case DecodingError.typeMismatch(_, let context) where !context.codingPath.isEmpty:
                "\(path(context)) isn't the kind of value it takes."
            case DecodingError.dataCorrupted(let context) where !context.codingPath.isEmpty:
                "\(path(context)) can't be read."
            default:
                "The body isn't the JSON this takes."
            }
    }

    func response(from request: Request, context: some RequestContext) throws -> Response {
        publicAPIErrorResponse(status: status, code: "invalid_request", message: reason)
    }
}

/// `request`'s body, as `Body`: when it isn't one, the API answers with 400 and why.
private func body<Body: Decodable & Sendable>(
    _: Body.Type, of request: Request, context: some RequestContext
) async throws -> Body {
    do {
        return try await JSONDecoder().decode(Body.self, from: request, context: context)
    } catch {
        throw UnreadableBody(error)
    }
}

private func publicConversationStatus(
    _ status: TurgaiDomain.ConversationStatus
) -> TurgaiModels.ConversationStatus {
    switch status {
    case .idle:
        .idle
    case .running:
        .running
    case .failed:
        .failed
    }
}

private func publicAPIErrorEvent(
    conversationID: TurgaiModels.ConversationID,
    code: String,
    message: String
) -> TurgaiModels.ChatEvent {
    .init(
        payload: .notice(
            conversationID: conversationID,
            turnID: nil,
            error: .init(code: code, message: message)
        )
    )
}

private func send(
    input: TurgaiModels.SendMessageRequest,
    text: String,
    conversation: APIConversation,
    as person: TurgaiDomain.UserID,
    to: Set<Participant>,
    dependencies: TurgaiRouteDependencies,
    names: ParticipantNames
) async throws -> TurgaiModels.ChatEvent {
    let session = LiveSession(
        id: UUID().uuidString, actorSystem: dependencies.system, linking: dependencies.linking, source: .web)
    // It runs while the socket does: its input finishes as the socket closes.
    async let _: Void = session.run()
    let outputTask = Task<TurgaiModels.ChatEvent?, Never> {
        var terminalEvent: TurgaiModels.ChatEvent?
        for await delivery in session.output {
            let event = PublicChatEvent(
                event: delivery.event,
                publicConversationID: conversation.publicID,
                author: try? await author(of: delivery.event, answeredBy: conversation.bot?.id, names: names)
            ).event
            await delivery.delivered()
            guard let event else { continue }
            if event.type == .turnCompleted || event.type == .turnFailed {
                terminalEvent = event
                break
            }
            // Taken with no turn to answer it: said only to people, it's done.
            if case .reply(.userMessage(_, nil, let id, _, _, _, _)) = delivery.event,
                id.rawValue == input.id.rawValue
            {
                terminalEvent = event
                break
            }
        }
        return terminalEvent
    }

    let connectReceipt = ConversationInputReceipt()
    await session.input.send(
        ConversationInputDelivery(
            in: conversation.space,
            input: .connect(conversation.domainID, for: person),
            receipt: connectReceipt
        )
    )
    guard await connectReceipt.wait() else {
        session.input.finish()
        outputTask.cancel()
        throw PublicAPIChatError.messageRejected
    }

    let messageReceipt = ConversationInputReceipt()
    let receivedAt = Date()
    await session.input.send(
        ConversationInputDelivery(
            in: conversation.space,
            input: .message(
                InboundMessage(
                    id: .init(rawValue: input.id.rawValue),
                    conversationID: conversation.domainID,
                    participantID: .init(channel: turgaiChannel, rawValue: person.key),
                    userID: person,
                    text: text,
                    receivedAt: receivedAt,
                    to: to
                ),
                turnID: .init()
            ),
            receipt: messageReceipt
        )
    )
    guard await messageReceipt.wait() else {
        session.input.finish()
        outputTask.cancel()
        throw PublicAPIChatError.messageRejected
    }
    let event =
        await outputTask.value
        ?? .init(
            payload: .messageAccepted(
                conversationID: conversation.publicID,
                turnID: nil,
                message: .init(id: input.id, role: .user, text: text, at: receivedAt)
            )
        )
    session.input.finish()
    return event
}

private enum PublicAPIChatError: Error {
    case messageRejected
}

private actor PublicChatSocketWriter {
    private let outbound: WebSocketOutboundWriter

    init(outbound: WebSocketOutboundWriter) {
        self.outbound = outbound
    }

    func write(_ event: TurgaiModels.ChatEvent) async throws {
        let data = try JSONEncoder().encode(event)
        guard let text = String(data: data, encoding: .utf8) else {
            throw PublicChatSocketWriterError.encodingFailed
        }
        try await outbound.write(.text(text))
    }
}

private enum PublicChatSocketWriterError: Error {
    case encodingFailed
}

private actor HTMLChatSocketWriter {
    private let outbound: WebSocketOutboundWriter
    /// Who the chat is shown to: their own messages are shown without their name.
    private let viewer: TurgaiDomain.UserID
    private let names: ParticipantNames
    private var activeTurns: Set<UUID> = []

    init(outbound: WebSocketOutboundWriter, viewer: TurgaiDomain.UserID, names: ParticipantNames) {
        self.outbound = outbound
        self.viewer = viewer
        self.names = names
    }

    func write(_ html: String) async throws {
        try await outbound.write(.text(html))
    }

    func write(_ event: OutboundEvent) async throws {
        // Another person's message is shown with their name.
        var author: ParticipantSummary?
        if case .reply(.userMessage(_, _, _, _, let person, _, _)) = event, person != viewer {
            author = try await names.summary(of: .person(person))
        }
        guard let fragment = fragment(for: event, author: author) else { return }
        try await write(fragment)
    }

    /// The HTML for `event`, its message said by `author` when that's shown, or `nil` for what the
    /// web chat doesn't show, such as a turn's steps.
    private func fragment(for event: OutboundEvent, author: ParticipantSummary?) -> String? {
        switch event {
        case .reply(let reply):
            switch reply {
            case .userMessage(_, _, let messageID, let text, _, _, let at):
                return ChatLiveFragment.accepted(
                    .init(id: .init(rawValue: messageID.rawValue), role: .user, text: text, author: author, at: at)
                )
            case .started:
                return ChatLiveFragment.started()
            case .phase(_, _, let phase), .keepAlive(_, _, let phase):
                return ChatLiveFragment.phase(
                    phase == .thinking ? .thinking : .typing
                )
            case .status(_, _, let message):
                return ChatLiveFragment.status(message)
            case .step:
                return nil
            case .partial(_, let turnID, let text):
                let id = turnID.rawValue
                let reply = ReplySoFar(id: .init(rawValue: id), text: text)
                if activeTurns.insert(id).inserted {
                    return ChatLiveFragment.appendedPartial(reply, turnID: .init(rawValue: id))
                } else {
                    return ChatLiveFragment.partial(reply, turnID: .init(rawValue: id))
                }
            case .finished(_, let turnID, let text, let at):
                let id = turnID.rawValue
                let message = TurgaiModels.Message(
                    id: .init(rawValue: id), role: .assistant, text: text, at: at
                )
                let fragment =
                    activeTurns.remove(id) == nil
                    ? ChatLiveFragment.appendedCompleted(message, turnID: .init(rawValue: id))
                    : ChatLiveFragment.completed(message, turnID: .init(rawValue: id))
                return fragment
            case .completed:
                return ChatLiveFragment.cleared()
            case .failed(_, _, let message):
                return ChatLiveFragment.failed(message)
            }
        case .notice(_, _, let text), .noticeWithActions(_, _, let text, _):
            return ChatLiveFragment.failed(text)
        case .reset:
            return ChatLiveFragment.cleared()
        case .asked(_, let request):
            return ChatLiveFragment.accessRequested(.init(request))
        case .answered(_, let request, let answer, _):
            return ChatLiveFragment.accessAnswered(request.id.rawValue, answer: answer.public)
        case .noted, .unnoted:
            return nil
        }
    }
}

/// What the browser chat's forms send over the socket.
private enum HTMLChatCommand: Decodable, Sendable {
    case message(text: String)
    case answer(id: UUID, answer: TurgaiModels.AccessAnswer)
    /// The reply being worked on stopped.
    case stop

    private enum CodingKeys: String, CodingKey {
        case command, text, id, answer
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        switch try values.decode(String.self, forKey: .command) {
        case "message":
            self = .message(text: try values.decode(String.self, forKey: .text))
        case "stop":
            self = .stop
        case "answer":
            self = .answer(
                id: try values.decode(UUID.self, forKey: .id),
                answer: try values.decode(TurgaiModels.AccessAnswer.self, forKey: .answer)
            )
        case let other:
            throw DecodingError.dataCorruptedError(
                forKey: .command, in: values, debugDescription: "Unknown chat command \(other)")
        }
    }
}

private func runHTMLChatSocket(
    inbound: WebSocketInboundStream,
    outbound: WebSocketOutboundWriter,
    session: LiveSession,
    conversation: APIConversation,
    participantID: ParticipantID,
    userID: TurgaiDomain.UserID,
    names: ParticipantNames
) async throws {
    let writer = HTMLChatSocketWriter(outbound: outbound, viewer: userID, names: names)
    // Ending the HTTP upgrade must end the session input: LiveSession.run()
    // only returns when input finishes, and TurgaiConnections removes the
    // conversation connection right after. Without this, every closed tab
    // leaves a ghost connection that can win first-connection reply
    // delivery and swallow `.finished` frames.
    defer { session.input.finish() }
    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask {
            for try await input in inbound.messages(maxSize: 1_000_000) {
                guard case .text(let text) = input,
                    let data = text.data(using: .utf8),
                    let command = try? JSONDecoder().decode(HTMLChatCommand.self, from: data)
                else { continue }

                let commandText: String
                switch command {
                case .message(let text):
                    commandText = text
                case .answer(let id, let answer):
                    let receipt = ConversationInputReceipt()
                    await session.input.send(
                        ConversationInputDelivery(
                            in: conversation.space,
                            input: .answer(
                                conversationID: conversation.domainID, AccessRequestID(id), answer.domain, by: userID),
                            receipt: receipt
                        )
                    )
                    _ = await receipt.wait()
                    continue
                case .stop:
                    let receipt = ConversationInputReceipt()
                    await session.input.send(
                        ConversationInputDelivery(
                            in: conversation.space, input: .stop(conversation.domainID, by: userID), receipt: receipt))
                    _ = await receipt.wait()
                    continue
                }
                let messageText = commandText.trimmed()
                guard !messageText.isEmpty else { continue }
                let messageID = TurgaiModels.MessageID()
                let receipt = ConversationInputReceipt()
                await session.input.send(
                    ConversationInputDelivery(
                        in: conversation.space,
                        input: .message(
                            InboundMessage(
                                id: .init(rawValue: messageID.rawValue),
                                conversationID: conversation.domainID,
                                participantID: participantID,
                                userID: userID,
                                text: messageText,
                                receivedAt: Date()
                            ),
                            turnID: .init()
                        ),
                        receipt: receipt
                    )
                )
                guard await receipt.wait() else { continue }
            }
        }
        group.addTask {
            for await delivery in session.output {
                // Fire-and-forget: the rendezvous ends at the session's
                // channel. A missed frame is reconstructed from journaled
                // history on the next attach; the conversation never waits
                // on a client.
                try await writer.write(delivery.event)
            }
        }
        _ = try await group.next()
        group.cancelAll()
    }
}

private struct PublicChatEvent: Sendable {
    /// What the client is sent, or `nil` for what the API doesn't show.
    let event: TurgaiModels.ChatEvent?

    /// `event` as the API sends it, its message said by `author`.
    init(
        event: OutboundEvent,
        publicConversationID: TurgaiModels.ConversationID,
        author: ParticipantSummary?
    ) {
        switch event {
        case .reply(let reply):
            self.event = Self.replyEvent(
                reply,
                publicConversationID: publicConversationID,
                author: author
            )
        case .notice(_, let turnID, let text),
            .noticeWithActions(_, let turnID, let text, _):
            self.event = .init(
                payload: .notice(
                    conversationID: publicConversationID,
                    turnID: turnID.map { .init(rawValue: $0.rawValue) },
                    error: .init(code: "notice", message: text)
                )
            )
        case .reset:
            self.event = .init(
                payload: .notice(
                    conversationID: publicConversationID,
                    turnID: nil,
                    error: .init(code: "reset", message: "Conversation reset.")
                )
            )
        case .asked(_, let request):
            self.event = .init(
                payload: .accessRequested(conversationID: publicConversationID, request: .init(request)))
        case .answered(_, let request, let answer, _):
            self.event = .init(
                payload: .accessAnswered(
                    conversationID: publicConversationID, requestID: request.id.rawValue, answer: answer.public))
        case .noted, .unnoted:
            self.event = nil
        }
    }

    private static func replyEvent(
        _ reply: ReplyEvent,
        publicConversationID: TurgaiModels.ConversationID,
        author: ParticipantSummary?
    ) -> TurgaiModels.ChatEvent {
        switch reply {
        case .userMessage(_, let turnID, let messageID, let text, _, let to, let at):
            return .init(
                payload: .messageAccepted(
                    conversationID: publicConversationID,
                    turnID: turnID.map { .init(rawValue: $0.rawValue) },
                    message: .init(
                        id: .init(rawValue: messageID.rawValue),
                        role: .user,
                        text: text,
                        author: author,
                        to: to.map(ParticipantRef.init),
                        at: at
                    )
                )
            )
        case .started(_, let turnID):
            return .init(
                payload: .turnStarted(
                    conversationID: publicConversationID,
                    turnID: .init(rawValue: turnID.rawValue)
                )
            )
        case .phase(_, let turnID, let phase), .keepAlive(_, let turnID, let phase):
            let publicPhase: TurgaiModels.ConversationPhase =
                switch phase {
                case .thinking: .thinking
                case .typing: .typing
                }
            return .init(
                payload: .turnPhase(
                    conversationID: publicConversationID,
                    turnID: .init(rawValue: turnID.rawValue),
                    phase: publicPhase
                )
            )
        case .status(_, let turnID, let message):
            return .init(
                payload: .turnStatus(
                    conversationID: publicConversationID,
                    turnID: .init(rawValue: turnID.rawValue),
                    activity: message
                )
            )
        case .step(_, let turnID, let step):
            return .init(
                payload: .turnStep(
                    conversationID: publicConversationID,
                    turnID: .init(rawValue: turnID.rawValue),
                    step: TurnStep(step)
                )
            )
        case .partial(_, let turnID, let text):
            return .init(
                payload: .turnPartial(
                    conversationID: publicConversationID,
                    turnID: .init(rawValue: turnID.rawValue),
                    reply: .init(id: .init(rawValue: turnID.rawValue), text: text, author: author)
                )
            )
        case .finished(_, let turnID, let text, let at):
            return .init(
                payload: .turnCompleted(
                    conversationID: publicConversationID,
                    turnID: .init(rawValue: turnID.rawValue),
                    message: .init(
                        id: .init(rawValue: turnID.rawValue),
                        role: .assistant,
                        text: text,
                        author: author,
                        at: at
                    )
                )
            )
        case .failed(_, let turnID, let message):
            return .init(
                payload: .turnFailed(
                    conversationID: publicConversationID,
                    turnID: turnID.map { .init(rawValue: $0.rawValue) },
                    error: .init(code: "turn_failed", message: message)
                )
            )
        case .completed:
            return .init(
                payload: .notice(
                    conversationID: nil,
                    turnID: nil,
                    error: .init(code: "completed", message: "Conversation completed.")
                ))
        }
    }
}

extension TurgaiModels.AccessAnswer {
    fileprivate var domain: TurgaiDomain.AccessAnswer {
        switch self {
        case .once: .once
        case .always: .always
        case .everyone: .everyone
        case .no: .no
        }
    }
}

extension TurgaiDomain.AccessAnswer {
    fileprivate var `public`: TurgaiModels.AccessAnswer {
        switch self {
        case .once: .once
        case .always: .always
        case .everyone: .everyone
        case .no: .no
        }
    }
}

extension TurgaiModels.AccessRequest {
    /// A request as a client shows it: exactly what was asked for, as people read it.
    fileprivate init(_ request: TurgaiDomain.AccessRequest) {
        self.init(id: request.id.rawValue, request: request.request.description)
    }
}

extension TurnStep {
    /// The domain's step, as the chat protocol sends it.
    init(_ step: ReplyStep) {
        switch step {
        case .toolCalled(let name, let arguments, let at):
            self.init(at: at, kind: .toolCalled(name: name, arguments: arguments))
        case .toolFinished(let name, let output, let failure, let at):
            self.init(at: at, kind: .toolFinished(name: name, output: output, failure: failure))
        case .noticed(let words, let at):
            self.init(at: at, kind: .noticed(words: words))
        }
    }
}

extension TurnRecord {
    /// A past turn, as the chat protocol sends it, identified as its live turn events identify it.
    init(_ turn: ConversationTurn) {
        let outcome: TurnOutcome =
            switch turn.outcome {
            case .running: .running
            case .replied(let text, let at): .replied(text, at: at)
            case .failed(let reason, let at): .failed(reason, at: at)
            case .cancelled(let at): .cancelled(at: at)
            case .interrupted(let at): .interrupted(at: at)
            }
        self.init(
            id: TurnID(rawValue: turn.id.rawValue), message: turn.message, startedAt: turn.startedAt,
            steps: turn.steps.map(TurnStep.init), outcome: outcome)
    }
}

/// Lets an API call through only from a client the API's configuration authorizes.
struct PublicAPIAuthorization<Context: RequestContext>: RouterMiddleware {
    let configuration: APIConfiguration

    @concurrent func handle(
        _ request: Request, context: Context, next: @concurrent (Request, Context) async throws -> Response
    ) async throws -> Response {
        guard configuration.authorizes(request) else { return publicAPIUnauthorizedResponse() }
        return try await next(request, context)
    }
}

extension TaskListing {
    /// `task`, as the API lists it.
    fileprivate init(_ task: KeptTask) {
        let title: String
        let does: String?
        switch task.of {
        case .chat(_, let name, let what):
            title = name
            does = what
        case .object(let object, let field):
            title = "\(object) · \(field)"
            does = nil
        }
        let when: When =
            switch task.due {
            case .schedule(let schedule): .repeating(schedule.described)
            case .timer(let timer): .once(timer.date)
            }
        let kind: Kind =
            switch (task.of, task.id) {
            case (.chat(let chat, let name, _), .schedule): .schedule(in: Chat(rawValue: chat.stableKey), named: name)
            case (.chat(let chat, let name, _), .timer): .reminder(in: Chat(rawValue: chat.stableKey), named: name)
            case (.object, _): .object
            }
        self.init(id: task.id.listed, title: title, does: does, when: when, paused: task.paused, kind: kind)
    }
}

extension KeptTask.ID {
    /// How the API names it: its durable schedule's or timer's id.
    fileprivate var listed: TaskListing.ID {
        switch self {
        case .schedule(let id): TaskListing.ID(rawValue: id.rawValue)
        case .timer(let id): TaskListing.ID(rawValue: id.rawValue)
        }
    }
}

extension ObjectListing {
    /// An object as the API lists it.
    fileprivate init(_ entry: ObjectEntry) {
        let endpoint = entry.object.id.node.endpoint
        self.init(
            id: entry.object.id.description, title: entry.id.description, summary: entry.description,
            actions: entry.actions, events: entry.events, node: "\(endpoint.host):\(endpoint.port)",
            made: DynamicObject.identity(of: entry.object.id).map { MadeObjectID(rawValue: $0.rawValue) })
    }
}

extension TurgaiModels.Conversation {
    /// `listing`, a conversation in Turgai's apps, as the API gives it.
    fileprivate init(_ listing: ConversationListing) {
        self.init(
            id: .init(rawValue: listing.id.externalAddress.rawValue),
            botID: listing.bot.map { .init(rawValue: $0.role) },
            title: listing.title, spaceID: listing.space.api, people: listing.people)
    }
}
