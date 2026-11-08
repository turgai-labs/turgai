import Crypto
import HTTPTypes
import Hummingbird
import HummingbirdWebSocket
import NIOCore
import TurgaiApplication
import TurgaiCalls
import TurgaiDomain
import TurgaiMemory
import TurgaiModels
import TurgaiObjects
import TurgaiPeople
import TurgaiSpaces

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
        api.get("bots") { _, _ in
            let bots = try await dependencies.agentProfiles.profiles()
                .filter { $0.availability == .enabled }
                .map { TurgaiModels.Bot(id: .init(rawValue: $0.id), name: $0.name) }
            return try publicAPIResponse(bots)
        }
        // Someone who doesn't sign in, coming in as a guest: one of Turgai's own space, with the
        // cookie that says they're them from now on.
        api.post("guests") { _, _ in
            let (guest, token) = try await dependencies.auth.newGuest()
            do {
                try await dependencies.webChatBridge.admit(guest: guest)
            } catch TurgaiWebChatBridgeError.runtimeUnavailable {
                return publicAPIErrorResponse(
                    status: .serviceUnavailable, code: "runtime_unavailable", message: "Turgai isn't running yet.")
            }
            var response = Response(status: .created)
            response.setCookie(TurgaiWebSupport.guestCookie(token))
            return response
        }
        // Who's signed in: their id and name.
        api.get("me") { request, _ in
            guard let person = await signedInPerson(from: request, auth: dependencies.auth) else {
                return signInRequired()
            }
            let names = ParticipantNames(auth: dependencies.auth, profiles: dependencies.agentProfiles)
            return try publicAPIResponse(Me(id: person.key, name: try await names.name(of: .person(person))))
        }
        // What's remembered about whoever's signed in, and whether they're remembered; remembering
        // turned on or off; and all of it forgotten.
        api.get("me/memory") { request, _ in
            guard let person = await signedInPerson(from: request, auth: dependencies.auth) else {
                return signInRequired()
            }
            let bridge = dependencies.webChatBridge
            return try publicAPIResponse(
                MemorySummary(
                    try await bridge.remembered(about: person), remembering: try await bridge.remembering(of: person)))
        }
        api.put("me/memory/remembering") { request, context in
            guard let person = await signedInPerson(from: request, auth: dependencies.auth) else {
                return signInRequired()
            }
            let input = try await body(SetRememberingRequest.self, of: request, context: context)
            try await dependencies.webChatBridge.setRemembering(Remembering(input.remembering), for: person)
            return Response(status: .noContent)
        }
        api.delete("me/memory") { request, _ in
            guard let person = await signedInPerson(from: request, auth: dependencies.auth) else {
                return signInRequired()
            }
            try await dependencies.webChatBridge.forgetMemory(of: person)
            return Response(status: .noContent)
        }
        registerConversations(on: api.group("conversations"), dependencies: dependencies)
        registerLinks(on: api.group("me/links"), dependencies: dependencies)
        registerSpaces(on: api.group("spaces"), dependencies: dependencies)
        registerMessages(on: api.group("conversations/:id/messages"), dependencies: dependencies)
        // What the signed-in account may read, listed on its behalf in its chat with a bot: the
        // default one, or `botID`'s.
        api.get("objects") { request, _ in
            guard let account = await TurgaiWebSupport.authenticatedAccount(from: request, auth: dependencies.auth)
            else { return publicAPIUnauthorizedResponse() }
            let entries = try await dependencies.webChatBridge.objects(listedTo: .account(account.id))
            return try publicAPIResponse(entries.map(ObjectListing.init))
        }
        // Shares one of the signed-in account's objects with everyone, or takes that back: only
        // one who may change it does.
        api.post("objects/:id/share") { request, context in
            guard let account = await TurgaiWebSupport.authenticatedAccount(from: request, auth: dependencies.auth)
            else { return publicAPIUnauthorizedResponse() }
            guard let id = context.parameters.get("id") else { return publicAPIUnauthorizedResponse() }
            let sharing = try await body(ObjectSharingRequest.self, of: request, context: context)
            let level: AccessLevel? =
                switch sharing.everyone {
                case .read: .read
                case .write: .write
                case .none: nil
                }
            do {
                try await dependencies.webChatBridge.share(
                    ObjectIdentity(rawValue: id), withEveryone: level, by: .account(account.id))
            } catch is NotAllowed {
                return Response(status: .forbidden)
            }
            return Response(status: .noContent)
        }
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
                    request.uri.queryParameters["conversationID"].map(String.init), readBy: owner.person,
                    bridge: dependencies.webChatBridge) != nil
            else {
                return .dontUpgrade
            }
            return .upgrade([:])
        } onUpgrade: { inbound, outbound, context in
            guard let owner = await chatOwner(from: context.request, auth: dependencies.auth),
                let conversation = try await apiConversation(
                    context.request.uri.queryParameters["conversationID"].map(String.init), readBy: owner.person,
                    bridge: dependencies.webChatBridge)
            else {
                try await outbound.close(.policyViolation, reason: "Conversation not found")
                return
            }
            let session: TurgaiConnections.WebSession
            do {
                session = try await dependencies.webChatBridge.openSession(id: WebSessionID())
            } catch {
                try await outbound.close(.policyViolation, reason: "Chat runtime unavailable")
                return
            }
            let userID = owner.person
            let names = ParticipantNames(auth: dependencies.auth, profiles: dependencies.agentProfiles)
            do {
                let history = try await publicAPIMessages(
                    try await dependencies.webChatBridge.conversationHistory(of: conversation.domainID, for: userID),
                    names: names)
                let status = try await dependencies.webChatBridge.conversationStatus(
                    of: conversation.domainID, for: userID)
                // The durable snapshot before live delivery, which could otherwise come first and be
                // replaced by it.
                let writer = HTMLChatSocketWriter(outbound: outbound, viewer: userID, names: names)
                try await writer.write(ChatLiveFragment.history(history.map { $0.shown(to: userID) }))
                if case .running = status {
                    try await writer.write(ChatLiveFragment.started())
                }
                guard try await open(conversation, on: session) else {
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
            let bridge = dependencies.webChatBridge
            let session: TurgaiConnections.WebSession
            do {
                session = try await bridge.openSession(id: WebSessionID())
            } catch {
                try await outbound.close(.policyViolation, reason: "Chat runtime unavailable")
                return
            }
            let person = owner.person
            let names = ParticipantNames(auth: dependencies.auth, profiles: dependencies.agentProfiles)
            let writer = PublicChatSocketWriter(outbound: outbound)
            let shown = ShownConversation()
            do {
                // Notices about the person's conversations in Turgai's apps. What's said in the one
                // it has open, and leaving it, come as that conversation's own events.
                let listener = try await bridge.followConversations(of: person) { notice in
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
                    case .joined, .said, .titled, .left:
                        payload = nil
                    }
                    guard let payload else { return }
                    try? await writer.write(.init(payload: payload))
                }
                defer { Task { try? await bridge.unfollow(listener) } }
                // What it's told about besides the conversation it shows, while it's joined.
                let topics = JoinedTopics()
                defer { Task { await topics.leaveAll() } }

                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask {
                        for try await input in inbound.messages(maxSize: 1_000_000) {
                            guard case .text(let text) = input,
                                let data = text.data(using: .utf8),
                                let command = try? JSONDecoder().decode(TurgaiModels.ChatCommand.self, from: data)
                            else { continue }
                            switch command {
                            case .open(let id):
                                guard
                                    let conversation = try await apiConversation(id.rawValue, readBy: person, bridge: bridge)
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
                                        ConversationInputDelivery(input: .detach(before.domainID), receipt: detached))
                                    _ = await detached.wait()
                                }
                                await shown.show(conversation)
                                try await writeOpened(conversation, for: person, on: writer, names: names, bridge: bridge)
                                guard try await open(conversation, on: session) else {
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
                                        input: .answer(
                                            conversationID: conversation.domainID, AccessRequestID(id), answer.domain,
                                            by: person),
                                        receipt: receipt))
                                _ = await receipt.wait()
                            case .push(let ref, let ask):
                                let reply = await answer(
                                    ask, for: person, topics: topics, writer: writer, bridge: bridge)
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
                                        of: delivery.event, answeredBy: conversation.agent, names: names)
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
            let listed = try await dependencies.webChatBridge.conversations(of: owner.person)
            return try publicAPIResponse(
                listed.filter { $0.id.channel == turgaiChannel }.map(TurgaiModels.Conversation.init))
        }

        // A new conversation, in a space the person is in, or Turgai's own, with them its first.
        conversations.post { request, context in
            guard let owner = await chatOwner(from: request, auth: dependencies.auth) else { return signInRequired() }
            let input = try await body(TurgaiModels.CreateConversationRequest.self, of: request, context: context)
            let profile: TurgaiAgentProfile?
            if let botID = input.botID {
                profile = try await dependencies.agentProfiles.profile(id: botID.rawValue)
            } else {
                profile = try await dependencies.agentProfiles.defaultProfile()
            }
            guard let profile, profile.availability == .enabled else {
                return publicAPIErrorResponse(
                    status: .notFound,
                    code: "bot_not_found",
                    message: "The requested bot does not exist or is disabled."
                )
            }
            let space: SpaceID?
            if let written = input.spaceID {
                guard let id = UUID(uuidString: written) else { return noSuchSpace() }
                space = SpaceID(rawValue: id)
            } else {
                space = nil
            }
            let conversationID = TurgaiDomain.ConversationID(
                channel: turgaiChannel, externalAddress: .init(UUID().uuidString))
            let startedIn: SpaceID
            do {
                startedIn = try await dependencies.webChatBridge.startConversation(
                    conversationID, in: space, agent: AgentProfileID(profile.id), by: owner.person)
            } catch let refusal as SpaceRefusal {
                return spaceRefused(refusal)
            }
            return try publicAPIResponse(
                TurgaiModels.Conversation(
                    id: .init(rawValue: conversationID.externalAddress.rawValue), botID: .init(rawValue: profile.id),
                    spaceID: startedIn.rawValue.uuidString),
                status: .created
            )
        }

        conversations.get(":id") { request, context in
            guard let owner = await chatOwner(from: request, auth: dependencies.auth) else { return signInRequired() }
            guard
                let conversation = try await apiConversation(
                    context.parameters.get("id"), readBy: owner.person, bridge: dependencies.webChatBridge)
            else { return conversationNotFound() }
            return try publicAPIResponse(conversation.info)
        }

        conversations.patch(":id") { request, context in
            guard let owner = await chatOwner(from: request, auth: dependencies.auth) else { return signInRequired() }
            guard
                let conversation = try await apiConversation(
                    context.parameters.get("id"), readBy: owner.person, bridge: dependencies.webChatBridge)
            else { return conversationNotFound() }
            let input = try await body(TurgaiModels.TitleConversationRequest.self, of: request, context: context)
            guard let title = ConversationTitle(input.title) else {
                return publicAPIErrorResponse(
                    status: .badRequest, code: "invalid_title",
                    message: "A conversation's title is some words, at most \(ConversationTitle.maximumLength) letters.")
            }
            try await dependencies.webChatBridge.title(conversation.domainID, title, by: owner.person)
            return Response(status: .noContent)
        }

        // Who's in it: its agent, and its people.
        conversations.get(":id/participants") { request, context in
            guard let owner = await chatOwner(from: request, auth: dependencies.auth) else { return signInRequired() }
            guard
                let conversation = try await apiConversation(
                    context.parameters.get("id"), readBy: owner.person, bridge: dependencies.webChatBridge)
            else { return conversationNotFound() }
            let names = ParticipantNames(auth: dependencies.auth, profiles: dependencies.agentProfiles)
            var participants: [ParticipantSummary] = []
            for participant in conversation.outline.participants {
                participants.append(try await names.summary(of: participant))
            }
            return try publicAPIResponse(
                participants.sorted { ($0.kind == .agent ? 0 : 1, $0.name) < ($1.kind == .agent ? 0 : 1, $1.name) })
        }

        // Someone added by one of its people: a person in its space, or an agent.
        conversations.post(":id/participants") { request, context in
            guard let owner = await chatOwner(from: request, auth: dependencies.auth) else { return signInRequired() }
            guard
                let conversation = try await apiConversation(
                    context.parameters.get("id"), readBy: owner.person, bridge: dependencies.webChatBridge)
            else { return conversationNotFound() }
            let input = try await body(ParticipantRef.self, of: request, context: context)
            guard let participant = Participant(input) else { return noSuchParticipant() }
            if case .agent(let agent) = participant {
                guard let profile = try await dependencies.agentProfiles.profile(id: agent.rawValue),
                    profile.availability == .enabled
                else {
                    return publicAPIErrorResponse(
                        status: .notFound, code: "bot_not_found",
                        message: "The requested bot does not exist or is disabled.")
                }
            }
            do {
                try await dependencies.webChatBridge.add(participant, to: conversation.domainID, by: owner.person)
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
            guard
                let conversation = try await apiConversation(
                    context.parameters.get("id"), readBy: owner.person, bridge: dependencies.webChatBridge)
            else { return conversationNotFound() }
            try await dependencies.webChatBridge.leave(conversation.domainID, as: owner.person)
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
                return publicAPIErrorResponse(status: .notFound, code: "not_linked", message: "No one like that is linked.")
            }
            try await linking.unlink(person, from: other)
            return Response(status: .noContent)
        }
    }

    /// The signed-in person's spaces: their list, making one, renaming it, leaving it, inviting
    /// someone, the invites that work, taking one back, and joining with one.
    private func registerSpaces(
        on spaces: RouterGroup<BasicWebSocketRequestContext>, dependencies: TurgaiRouteDependencies
    ) {
        let auth = dependencies.auth
        let bridge = dependencies.webChatBridge

        /// What `request`'s person asks of spaces, refused when no one signed in or the runtime
        /// isn't running, and said back as the API says it.
        @Sendable func answering(
            _ request: Request, _ answer: (TurgaiDomain.UserID, Spaces) async throws -> Response
        ) async throws -> Response {
            guard let person = await signedInPerson(from: request, auth: auth) else { return signInRequired() }
            do {
                return try await answer(person, try await bridge.spaces())
            } catch let refusal as SpaceRefusal {
                return spaceRefused(refusal)
            } catch TurgaiWebChatBridgeError.runtimeUnavailable {
                return publicAPIErrorResponse(
                    status: .serviceUnavailable, code: "runtime_unavailable", message: "Turgai isn't running yet.")
            }
        }

        spaces.get { request, _ in
            try await answering(request) { person, spaces in
                try publicAPIResponse(try await spaces.list(for: person).map(SpaceSummary.init))
            }
        }

        spaces.post { request, context in
            try await answering(request) { person, spaces in
                let input = try await body(MakeSpaceRequest.self, of: request, context: context)
                guard let name = SpaceName(input.name) else { return nameRequired() }
                return try publicAPIResponse(
                    SpaceSummary(try await spaces.make(named: name, by: person)), status: .created)
            }
        }

        spaces.patch(":space") { request, context in
            try await answering(request) { person, spaces in
                guard let space = spaceID(in: context) else { return noSuchSpace() }
                let input = try await body(RenameSpaceRequest.self, of: request, context: context)
                guard let name = SpaceName(input.name) else { return nameRequired() }
                return try publicAPIResponse(SpaceSummary(try await spaces.rename(space, to: name, by: person)))
            }
        }

        spaces.delete(":space/me") { request, context in
            try await answering(request) { person, spaces in
                guard let space = spaceID(in: context) else { return noSuchSpace() }
                try await spaces.leave(space, as: person)
                return Response(status: .noContent)
            }
        }

        spaces.post(":space/invites") { request, context in
            try await answering(request) { person, spaces in
                guard let space = spaceID(in: context) else { return noSuchSpace() }
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
                let (invite, token) = try await spaces.invite(to: space, by: person, for: lifetime)
                return try publicAPIResponse(
                    SpaceInviteOffer(
                        id: invite.id.rawValue.uuidString, token: token.rawValue,
                        link: SpaceInviteLink(spaceID: space.rawValue.uuidString, token: token.rawValue).description,
                        expiresAt: invite.expiresAt),
                    status: .created)
            }
        }

        spaces.get(":space/people") { request, context in
            try await answering(request) { person, spaces in
                guard let space = spaceID(in: context) else { return noSuchSpace() }
                let names = ParticipantNames(auth: auth, profiles: dependencies.agentProfiles)
                var people: [SpacePerson] = []
                for (person, role) in try await spaces.people(in: space, for: person) {
                    people.append(
                        SpacePerson(
                            id: person.key, name: try await names.name(of: .person(person)),
                            role: role == .admin ? .admin : .member))
                }
                return try publicAPIResponse(people.sorted { $0.name < $1.name })
            }
        }

        spaces.get(":space/invites") { request, context in
            try await answering(request) { person, spaces in
                guard let space = spaceID(in: context) else { return noSuchSpace() }
                return try publicAPIResponse(
                    try await spaces.invites(to: space, for: person).map {
                        SpaceInviteListing(id: $0.id.rawValue.uuidString, expiresAt: $0.expiresAt)
                    })
            }
        }

        spaces.delete(":space/invites/:invite") { request, context in
            try await answering(request) { person, spaces in
                guard let space = spaceID(in: context),
                    let invite = context.parameters.get("invite").flatMap(UUID.init(uuidString:))
                else { return noSuchSpace() }
                try await spaces.takeBack(SpaceInviteID(rawValue: invite), to: space, by: person)
                return Response(status: .noContent)
            }
        }

        spaces.post(":space/join") { request, context in
            try await answering(request) { person, spaces in
                guard let space = spaceID(in: context) else { return noSuchSpace() }
                let input = try await body(JoinSpaceRequest.self, of: request, context: context)
                return try publicAPIResponse(
                    SpaceSummary(try await spaces.join(space, with: SpaceInviteToken(input.token), as: person)))
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
                    context.parameters.get("id"), readBy: owner.person, bridge: dependencies.webChatBridge)
            else { return conversationNotFound() }
            do {
                let history = try await dependencies.webChatBridge.conversationHistory(
                    of: conversation.domainID, for: owner.person)
                let names = ParticipantNames(auth: dependencies.auth, profiles: dependencies.agentProfiles)
                return try publicAPIResponse(try await publicAPIMessages(history, names: names))
            } catch {
                return publicAPIErrorResponse(
                    status: .serviceUnavailable,
                    code: "runtime_unavailable",
                    message: "The conversation runtime is unavailable."
                )
            }
        }


        messages.post { request, context in
            guard let owner = await chatOwner(from: request, auth: dependencies.auth) else { return signInRequired() }
            guard
                let conversation = try await apiConversation(
                    context.parameters.get("id"), readBy: owner.person, bridge: dependencies.webChatBridge)
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
                    bridge: dependencies.webChatBridge,
                    names: ParticipantNames(auth: dependencies.auth, profiles: dependencies.agentProfiles)
                )
                var response = try publicAPIResponse(event)
                if case .guest(_, let token) = owner { response.setCookie(TurgaiWebSupport.guestCookie(token)) }
                return response
            } catch PublicAPIChatError.runtimeUnavailable {
                return publicAPIErrorResponse(
                    status: .serviceUnavailable,
                    code: "runtime_unavailable",
                    message: "The conversation runtime is unavailable."
                )
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
    let domainID: TurgaiDomain.ConversationID
    /// Its space, and who's in it.
    let outline: ConversationOutline
    /// The agent that answers in it.
    let agent: AgentProfileID

    /// What the API calls it: the id it was given as it started.
    var publicID: TurgaiModels.ConversationID { .init(rawValue: domainID.externalAddress.rawValue) }

    var info: TurgaiModels.Conversation {
        .init(id: publicID, botID: .init(rawValue: agent.rawValue), spaceID: outline.space.rawValue.uuidString)
    }
}

/// The conversation the API calls `id`, as `person` reads it: none when there's no such
/// conversation, or they're not one of its people, which the API doesn't tell apart.
private func apiConversation(
    _ id: String?, readBy person: TurgaiDomain.UserID, bridge: TurgaiWebChatBridge
) async throws -> APIConversation? {
    guard let id, let minted = UUID(uuidString: id) else { return nil }
    let domainID = TurgaiDomain.ConversationID(channel: turgaiChannel, externalAddress: .init(minted.uuidString))
    let outline: ConversationOutline
    do {
        outline = try await bridge.conversation(domainID, readBy: person)
    } catch is ConversationRefusal {
        return nil
    }
    guard let agent = outline.agent else { return nil }
    return APIConversation(domainID: domainID, outline: outline, agent: agent)
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

/// `person` told about `topic` on the connection `writer` writes to, as it changes, until the
/// returned function is called.
private func follow(
    _ topic: TurgaiModels.ChatTopic, for person: TurgaiDomain.UserID, writer: PublicChatSocketWriter,
    bridge: TurgaiWebChatBridge
) async throws -> @Sendable () async -> Void {
    switch topic {
    case .memory:
        let listener = try await bridge.followMemory(of: person) {
            try? await writer.write(.init(payload: .memoryChanged))
        }
        return { try? await bridge.unfollowMemory(listener) }
    }
}

/// The answer to `ask`, asked by `person` on the connection `writer` writes to: a topic joined or
/// left, what's remembered about them, forgetting it, or remembering on or off.
private func answer(
    _ ask: TurgaiModels.ChatAsk, for person: TurgaiDomain.UserID, topics: JoinedTopics,
    writer: PublicChatSocketWriter, bridge: TurgaiWebChatBridge
) async -> TurgaiModels.ChatReply {
    do {
        switch ask {
        case .join(let topic):
            try await topics.join(topic) { try await follow(topic, for: person, writer: writer, bridge: bridge) }
            return .ok
        case .leave(let topic):
            await topics.leave(topic)
            return .ok
        case .memory:
            return .memory(
                MemorySummary(
                    try await bridge.remembered(about: person), remembering: try await bridge.remembering(of: person)))
        case .forgetMemory:
            try await bridge.forgetMemory(of: person)
            return .ok
        case .setRemembering(let remembering):
            try await bridge.setRemembering(Remembering(remembering), for: person)
            return .ok
        }
    } catch {
        return .failed(TurgaiModels.ChatError(code: "push_failed", message: "That didn't work. Try again."))
    }
}

private actor ShownConversation {
    private(set) var conversation: APIConversation?

    func show(_ conversation: APIConversation) {
        self.conversation = conversation
    }
}

/// `session` attached to `conversation`, so its live events come: whether it was.
private func open(_ conversation: APIConversation, on session: TurgaiConnections.WebSession) async throws -> Bool {
    let receipt = ConversationInputReceipt()
    await session.input.send(ConversationInputDelivery(input: .connect(conversation.domainID), receipt: receipt))
    return await receipt.wait()
}

/// What an app's connection is sent as it opens `conversation` for `person`: that it's open, what's
/// been said in it, and the agent's past turns.
private func writeOpened(
    _ conversation: APIConversation, for person: TurgaiDomain.UserID, on writer: PublicChatSocketWriter,
    names: ParticipantNames, bridge: TurgaiWebChatBridge
) async throws {
    let history = try await publicAPIMessages(
        try await bridge.conversationHistory(of: conversation.domainID, for: person), names: names)
    let status = try await bridge.conversationStatus(of: conversation.domainID, for: person)
    try await writer.write(
        .init(
            payload: .ready(
                conversationID: conversation.publicID, botID: .init(rawValue: conversation.agent.rawValue),
                status: publicConversationStatus(status), you: person.key)))
    try await writer.write(.init(payload: .history(conversationID: conversation.publicID, messages: history)))
    // The agent's turns, step by step; the chat works without them.
    let turns = (try? await bridge.conversationTurns(of: conversation.domainID, askedBy: person)) ?? []
    try await writer.write(
        .init(payload: .turns(conversationID: conversation.publicID, turns: turns.map(TurnRecord.init))))
}

/// `request`, said by `person` in `conversation` through `session`: what's wrong with it, or that
/// it was refused, written back.
private func say(
    _ request: TurgaiModels.SendMessageRequest, in conversation: APIConversation, as person: TurgaiDomain.UserID,
    on session: TurgaiConnections.WebSession, writer: PublicChatSocketWriter
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
    case .guestsStayOut: publicAPIErrorResponse(status: .forbidden, code: "guests_stay_out", message: refusal.description)
    case .alreadyStarted: publicAPIErrorResponse(status: .conflict, code: "already_started", message: refusal.description)
    case .oneAgentForNow:
        publicAPIErrorResponse(status: .conflict, code: "one_agent_for_now", message: refusal.description)
    case .addresseeNotInIt:
        publicAPIErrorResponse(status: .badRequest, code: "addressee_not_in_it", message: refusal.description)
    }
}

/// The answer for a participant the API can't name.
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
            self = .agent(AgentProfileID(reference.id))
        }
    }
}

extension ParticipantRef {
    /// `participant` as the API refers to them.
    fileprivate init(_ participant: Participant) {
        switch participant {
        case .person(let person): self.init(kind: .person, id: person.key)
        case .agent(let agent): self.init(kind: .agent, id: agent.rawValue)
        }
    }
}

/// What participants are called, as the API shows them, each looked up once: an account by its
/// username, an agent by its name, a Telegram person and a guest by what they are.
private actor ParticipantNames {
    private let auth: TurgaiAuth
    private let profiles: TurgaiAgentProfileStore
    private var known: [Participant: String] = [:]

    init(auth: TurgaiAuth, profiles: TurgaiAgentProfileStore) {
        self.auth = auth
        self.profiles = profiles
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
            case .agent(let agent): try await profiles.profile(id: agent.rawValue)?.name ?? agent.rawValue
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
            return Self(id: id, role: role, text: text)
        }
        return self
    }
}

extension ParticipantSummary {
    /// `participant` as the API names them, called `name`.
    fileprivate init(_ participant: Participant, name: String) {
        switch participant {
        case .person(let person): self.init(kind: .person, id: person.key, name: name)
        case .agent(let agent): self.init(kind: .agent, id: agent.rawValue, name: name)
        }
    }
}

/// The answer for a conversation the person can't read, or that isn't there.
private func conversationNotFound() -> Response {
    publicAPIErrorResponse(status: .notFound, code: "conversation_not_found", message: "The conversation does not exist.")
}

/// The person a request is from: its signed-in account's.
private func signedInPerson(from request: Request, auth: TurgaiAuth) async -> TurgaiDomain.UserID? {
    await TurgaiWebSupport.authenticatedAccount(from: request, auth: auth).map { .account($0.id) }
}

/// The space a path names.
private func spaceID(in context: BasicWebSocketRequestContext) -> SpaceID? {
    context.parameters.get("space").flatMap(UUID.init(uuidString:)).map(SpaceID.init(rawValue:))
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
        case .onlyAdmins: (.forbidden, "only_admins")
        case .notInIt: (.notFound, "not_in_it")
        case .lastAdmin: (.conflict, "last_admin")
        case .inviteDoesNotWork: (.conflict, "invite_does_not_work")
        }
    return publicAPIErrorResponse(status: status, code: code, message: refusal.description)
}

extension SpaceSummary {
    fileprivate init(_ listing: SpaceListing) {
        self.init(
            id: listing.id.rawValue.uuidString, name: listing.name.rawValue,
            role: listing.role == .admin ? .admin : .member)
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
        let author: ParticipantSummary? = if let author = entry.author { try await names.summary(of: author) } else { nil }
        messages.append(
            .init(
                id: .init(rawValue: UUID(uuidString: value) ?? UUID()),
                role: entry.role == .user ? .user : .assistant,
                text: entry.text,
                author: author,
                to: entry.to.map(ParticipantRef.init)
            ))
    }
    return messages
}

/// Who said what `event` carries, as the API names them: a person's message's author, or the agent
/// that answers for what it says; none for the rest.
private func author(
    of event: OutboundEvent, answeredBy agent: AgentProfileID, names: ParticipantNames
) async throws -> ParticipantSummary? {
    switch event {
    case .reply(.userMessage(_, _, _, _, let person, _)): try await names.summary(of: .person(person))
    case .reply(.partial), .reply(.finished): try await names.summary(of: .agent(agent))
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
    bridge: TurgaiWebChatBridge,
    names: ParticipantNames
) async throws -> TurgaiModels.ChatEvent {
    let session: TurgaiConnections.WebSession
    do {
        session = try await bridge.openSession(id: WebSessionID())
    } catch {
        throw PublicAPIChatError.runtimeUnavailable
    }
    let outputTask = Task<TurgaiModels.ChatEvent?, Never> {
        var terminalEvent: TurgaiModels.ChatEvent?
        for await delivery in session.output {
            let event = PublicChatEvent(
                event: delivery.event,
                publicConversationID: conversation.publicID,
                author: try? await author(of: delivery.event, answeredBy: conversation.agent, names: names)
            ).event
            await delivery.delivered()
            guard let event else { continue }
            if event.type == .turnCompleted || event.type == .turnFailed {
                terminalEvent = event
                break
            }
            // Taken with no turn to answer it: said only to people, it's done.
            if case .reply(.userMessage(_, nil, let id, _, _, _)) = delivery.event,
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
            input: .connect(conversation.domainID),
            receipt: connectReceipt
        )
    )
    guard await connectReceipt.wait() else {
        session.input.finish()
        outputTask.cancel()
        throw PublicAPIChatError.messageRejected
    }

    let messageReceipt = ConversationInputReceipt()
    await session.input.send(
        ConversationInputDelivery(
            input: .message(
                InboundMessage(
                    id: .init(rawValue: input.id.rawValue),
                    conversationID: conversation.domainID,
                    participantID: .init(channel: turgaiChannel, rawValue: person.key),
                    userID: person,
                    text: text,
                    receivedAt: Date(),
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
                message: .init(id: input.id, role: .user, text: text)
            )
        )
    session.input.finish()
    return event
}

private enum PublicAPIChatError: Error {
    case runtimeUnavailable
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
        if case .reply(.userMessage(_, _, _, _, let person, _)) = event, person != viewer {
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
            case .userMessage(_, _, let messageID, let text, _, _):
                return ChatLiveFragment.accepted(
                    .init(id: .init(rawValue: messageID.rawValue), role: .user, text: text, author: author)
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
                let message = TurgaiModels.Message(
                    id: .init(rawValue: id), role: .assistant, text: text
                )
                if activeTurns.insert(id).inserted {
                    return ChatLiveFragment.appendedPartial(message, turnID: .init(rawValue: id))
                } else {
                    return ChatLiveFragment.partial(message, turnID: .init(rawValue: id))
                }
            case .finished(_, let turnID, let text):
                let id = turnID.rawValue
                let message = TurgaiModels.Message(
                    id: .init(rawValue: id), role: .assistant, text: text
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

    private enum CodingKeys: String, CodingKey {
        case command, text, id, answer
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        switch try values.decode(String.self, forKey: .command) {
        case "message":
            self = .message(text: try values.decode(String.self, forKey: .text))
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
    session: TurgaiConnections.WebSession,
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
                            input: .answer(
                                conversationID: conversation.domainID, AccessRequestID(id), answer.domain, by: userID),
                            receipt: receipt
                        )
                    )
                    _ = await receipt.wait()
                    continue
                }
                let messageText = commandText.trimmed()
                guard !messageText.isEmpty else { continue }
                let messageID = TurgaiModels.MessageID()
                let receipt = ConversationInputReceipt()
                await session.input.send(
                    ConversationInputDelivery(
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
        case .userMessage(_, let turnID, let messageID, let text, _, let to):
            return .init(
                payload: .messageAccepted(
                    conversationID: publicConversationID,
                    turnID: turnID.map { .init(rawValue: $0.rawValue) },
                    message: .init(
                        id: .init(rawValue: messageID.rawValue),
                        role: .user,
                        text: text,
                        author: author,
                        to: to.map(ParticipantRef.init)
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
                    message: .init(
                        id: .init(rawValue: turnID.rawValue),
                        role: .assistant,
                        text: text,
                        author: author
                    )
                )
            )
        case .finished(_, let turnID, let text):
            return .init(
                payload: .turnCompleted(
                    conversationID: publicConversationID,
                    turnID: .init(rawValue: turnID.rawValue),
                    message: .init(
                        id: .init(rawValue: turnID.rawValue),
                        role: .assistant,
                        text: text,
                        author: author
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
            id: .init(rawValue: listing.id.externalAddress.rawValue), botID: .init(rawValue: listing.agent.rawValue),
            title: listing.title, spaceID: listing.space.rawValue.uuidString)
    }
}
