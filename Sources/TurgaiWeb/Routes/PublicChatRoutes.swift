import Crypto
import HTTPTypes
import Hummingbird
import HummingbirdWebSocket
import NIOCore
import TurgaiApplication
import TurgaiDomain
import TurgaiModels
import TurgaiObjects

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

private let publicAPIChannel = ChannelID("api")
private let accountChatChannel = ChannelID("account")

extension TurgaiMainWebApp {
    func registerPublicChatRoutes(
        on router: Router<BasicWebSocketRequestContext>,
        dependencies: TurgaiRouteDependencies
    ) {
        // Every API call comes from a client the API's configuration lets in.
        let api = router.group("api/v1").add(
            middleware: PublicAPIAuthorization(configuration: dependencies.apiConfiguration))
        api.get("bots") { _, _ in
            let bots = await dependencies.agentProfiles.profiles()
                .filter { $0.availability == .enabled }
                .map { TurgaiModels.Bot(id: .init(rawValue: $0.id), name: $0.name) }
            return try publicAPIResponse(bots)
        }
        registerConversations(on: api.group("conversations"), dependencies: dependencies)
        registerMessages(on: api.group("conversations/:id/messages"), dependencies: dependencies)
        // What the signed-in account may read, listed on its behalf in its chat with a bot: the
        // default one, or `botID`'s.
        api.get("objects") { request, _ in
            let owner = await chatOwner(from: request, auth: dependencies.auth)
            guard case .account = owner,
                let conversation = await chatConversation(
                    owner: owner, conversationID: nil, botID: request.uri.queryParameters["botID"].map(String.init),
                    profiles: dependencies.agentProfiles)
            else { return publicAPIUnauthorizedResponse() }
            let entries = try await dependencies.webChatBridge.objects(
                listedTo: conversation.person(for: owner), in: conversation.domainID,
                role: .profile(conversation.profile.id))
            return try publicAPIResponse(entries.map(ObjectListing.init))
        }
        // Shares one of the signed-in account's objects with everyone, or takes that back: only
        // one who may change it does.
        api.post("objects/:id/share") { request, context in
            let owner = await chatOwner(from: request, auth: dependencies.auth)
            guard case .account = owner,
                let conversation = await chatConversation(
                    owner: owner, conversationID: nil, botID: nil, profiles: dependencies.agentProfiles),
                let id = context.parameters.get("id")
            else { return publicAPIUnauthorizedResponse() }
            guard
                let sharing = try? await JSONDecoder().decode(
                    ObjectSharingRequest.self, from: request, context: context)
            else { return Response(status: .badRequest) }
            let level: AccessLevel? =
                switch sharing.everyone {
                case .read: .read
                case .write: .write
                case .none: nil
                }
            do {
                try await dependencies.webChatBridge.share(
                    ObjectIdentity(rawValue: id), withEveryone: level, by: conversation.person(for: owner),
                    in: conversation.domainID, role: .profile(conversation.profile.id))
            } catch is NotAllowed {
                return Response(status: .forbidden)
            }
            return Response(status: .noContent)
        }
        registerChatSocket(on: router, dependencies: dependencies)
    }

    /// The live chat, over a WebSocket. Not behind the API's middleware: a socket it refuses isn't
    /// upgraded, rather than answered.
    private func registerChatSocket(
        on router: Router<BasicWebSocketRequestContext>, dependencies: TurgaiRouteDependencies
    ) {
        router.ws("/api/v1/chat") { request, _ in
            guard dependencies.apiConfiguration.authorizes(request) else {
                return .dontUpgrade
            }
            switch (request.uri.queryParameters["conversationID"], request.uri.queryParameters["botID"]) {
            case (.some(let conversationID), _):
                guard
                    await apiConversation(
                        from: String(conversationID),
                        profiles: dependencies.agentProfiles
                    ) != nil
                else { return .dontUpgrade }
            case (nil, .some(let botID)):
                guard let profile = await dependencies.agentProfiles.profile(id: String(botID)),
                    profile.availability == .enabled
                else { return .dontUpgrade }
            case (nil, nil):
                guard await dependencies.agentProfiles.defaultProfile() != nil else {
                    return .dontUpgrade
                }
            }
            return .upgrade([:])
        } onUpgrade: { inbound, outbound, context in
            let query = context.request.uri.queryParameters
            let owner = await chatOwner(from: context.request, auth: dependencies.auth)
            guard
                let conversation = await chatConversation(
                    owner: owner,
                    conversationID: query["conversationID"].map(String.init),
                    botID: query["botID"].map(String.init),
                    profiles: dependencies.agentProfiles
                )
            else {
                try await outbound.close(.policyViolation, reason: "Bot or conversation not found")
                return
            }
            await dependencies.webChatBridge.rememberConversation(conversation.domainID)
            let session: TurgaiConnections.WebSession
            do {
                session = try await dependencies.webChatBridge.openSession(id: WebSessionID())
            } catch {
                try await outbound.close(.policyViolation, reason: "Chat runtime unavailable")
                return
            }

            let participantID = ParticipantID(
                channel: conversation.domainID.channel,
                rawValue: conversation.domainID.stableKey
            )
            let userID = conversation.person(for: owner)

            do {
                let writer = PublicChatSocketWriter(outbound: outbound)
                let history = try await dependencies.webChatBridge.conversationHistory(
                    for: conversation.domainID,
                    role: .profile(conversation.profile.id)
                )
                let status = try await dependencies.webChatBridge.conversationStatus(
                    for: conversation.domainID,
                    role: .profile(conversation.profile.id)
                )

                // Write the durable snapshot before attaching live delivery.
                // Otherwise a live update can arrive first and then be erased
                // by the history OOB replacement.
                if query["format"] == "html" {
                    let htmlWriter = HTMLChatSocketWriter(outbound: outbound)
                    try await htmlWriter.write(
                        ChatLiveFragment.history(history.map(publicAPIMessage))
                    )
                    if case .running = status {
                        try await htmlWriter.write(ChatLiveFragment.started())
                    }
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
                    try await outbound.close(.policyViolation, reason: "Could not open conversation")
                    return
                }

                if query["format"] == "html" {
                    try await runHTMLChatSocket(
                        inbound: inbound,
                        outbound: outbound,
                        session: session,
                        conversation: conversation,
                        participantID: participantID,
                        userID: userID
                    )
                    return
                }
                try await writer.write(
                    .init(
                        payload: .ready(
                            conversationID: conversation.publicID,
                            botID: .init(rawValue: conversation.profile.id),
                            status: publicConversationStatus(status)
                        ))
                )
                try await writer.write(
                    .init(
                        payload: .history(
                            conversationID: conversation.publicID,
                            messages: history.map(publicAPIMessage)
                        ))
                )
                // The agent's turns, step by step; the chat works without them.
                let turns =
                    (try? await dependencies.webChatBridge.conversationTurns(
                        for: conversation.domainID, role: .profile(conversation.profile.id), askedBy: userID)) ?? []
                try await writer.write(
                    .init(payload: .turns(conversationID: conversation.publicID, turns: turns.map(TurnRecord.init)))
                )

                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask {
                        for try await input in inbound.messages(maxSize: 1_000_000) {
                            guard case .text(let text) = input,
                                let data = text.data(using: .utf8),
                                let chatCommand = try? JSONDecoder().decode(
                                    TurgaiModels.ChatCommand.self,
                                    from: data
                                )
                            else { continue }
                            let command: TurgaiModels.SendMessageRequest
                            switch chatCommand {
                            case .message(let request):
                                command = request
                            case .answer(let id, let answer):
                                let receipt = ConversationInputReceipt()
                                await session.input.send(
                                    ConversationInputDelivery(
                                        input: .answer(
                                            conversationID: conversation.domainID, AccessRequestID(id), answer.domain,
                                            by: userID),
                                        receipt: receipt
                                    )
                                )
                                _ = await receipt.wait()
                                continue
                            }
                            let messageText = command.text.trimmed()
                            guard !messageText.isEmpty else {
                                try await writer.write(
                                    publicAPIErrorEvent(
                                        conversationID: conversation.publicID,
                                        code: "empty_message",
                                        message: "A message must contain text."
                                    )
                                )
                                continue
                            }

                            let receipt = ConversationInputReceipt()
                            await session.input.send(
                                ConversationInputDelivery(
                                    input: .message(
                                        InboundMessage(
                                            id: .init(rawValue: command.id.rawValue),
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
                            guard await receipt.wait() else {
                                try await writer.write(
                                    publicAPIErrorEvent(
                                        conversationID: conversation.publicID,
                                        code: "message_rejected",
                                        message: "The message could not be accepted."
                                    )
                                )
                                continue
                            }
                            try await writer.write(
                                .init(
                                    payload: .messageAccepted(
                                        conversationID: conversation.publicID,
                                        turnID: nil,
                                        message: .init(
                                            id: command.id,
                                            role: .user,
                                            text: messageText
                                        )
                                    ))
                            )
                        }
                    }
                    group.addTask {
                        for await delivery in session.output {
                            try await writer.write(
                                PublicChatEvent(
                                    event: delivery.event,
                                    publicConversationID: conversation.publicID
                                ).event
                            )
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

    /// The API's conversations: listing, starting and reading one.
    private func registerConversations(
        on conversations: RouterGroup<BasicWebSocketRequestContext>, dependencies: TurgaiRouteDependencies
    ) {
        conversations.get { _, _ in
            let persistedIDs = await dependencies.webChatBridge.conversationIDs()
            var conversations: [TurgaiModels.Conversation] = []
            for domainID in persistedIDs where domainID.channel == publicAPIChannel {
                guard
                    let conversation = await apiConversation(
                        from: domainID.externalAddress.rawValue,
                        profiles: dependencies.agentProfiles
                    )
                else { continue }
                conversations.append(conversation.info)
            }
            return try publicAPIResponse(conversations)
        }


        conversations.post { request, context in
            let input: TurgaiModels.CreateConversationRequest
            do {
                input = try await JSONDecoder().decode(
                    TurgaiModels.CreateConversationRequest.self,
                    from: request,
                    context: context
                )
            } catch {
                return publicAPIErrorResponse(
                    status: .badRequest,
                    code: "invalid_request",
                    message: "The conversation request is invalid."
                )
            }

            let profile: TurgaiAgentProfile?
            if let botID = input.botID {
                profile = await dependencies.agentProfiles.profile(id: botID.rawValue)
            } else {
                profile = await dependencies.agentProfiles.defaultProfile()
            }
            guard let profile, profile.availability == .enabled else {
                return publicAPIErrorResponse(
                    status: .notFound,
                    code: "bot_not_found",
                    message: "The requested bot does not exist or is disabled."
                )
            }

            let conversationID = apiConversationID(profileID: profile.id)
            await dependencies.webChatBridge.rememberConversation(conversationID)
            return try publicAPIResponse(
                TurgaiModels.Conversation(
                    id: publicAPIConversationID(for: conversationID),
                    botID: .init(rawValue: profile.id)
                ),
                status: .created
            )
        }


        conversations.get(":id") { _, context in
            guard
                let conversation = await apiConversation(
                    from: context.parameters.get("id"),
                    profiles: dependencies.agentProfiles
                )
            else {
                return publicAPIErrorResponse(
                    status: .notFound,
                    code: "conversation_not_found",
                    message: "The conversation does not exist."
                )
            }
            return try publicAPIResponse(conversation.info)
        }

    }

    /// A conversation's messages, through the API: reading them, and sending one.
    private func registerMessages(
        on messages: RouterGroup<BasicWebSocketRequestContext>, dependencies: TurgaiRouteDependencies
    ) {
        messages.get { _, context in
            guard
                let conversation = await apiConversation(
                    from: context.parameters.get("id"),
                    profiles: dependencies.agentProfiles
                )
            else {
                return publicAPIErrorResponse(
                    status: .notFound,
                    code: "conversation_not_found",
                    message: "The conversation does not exist."
                )
            }
            do {
                let history = try await dependencies.webChatBridge.conversationHistory(
                    for: conversation.domainID,
                    role: .profile(conversation.profile.id)
                )
                return try publicAPIResponse(history.map(publicAPIMessage))
            } catch {
                return publicAPIErrorResponse(
                    status: .serviceUnavailable,
                    code: "runtime_unavailable",
                    message: "The conversation runtime is unavailable."
                )
            }
        }


        messages.post { request, context in
            guard
                let conversation = await apiConversation(
                    from: context.parameters.get("id"),
                    profiles: dependencies.agentProfiles
                )
            else {
                return publicAPIErrorResponse(
                    status: .notFound,
                    code: "conversation_not_found",
                    message: "The conversation does not exist."
                )
            }
            let input: TurgaiModels.SendMessageRequest
            do {
                input = try await JSONDecoder().decode(
                    TurgaiModels.SendMessageRequest.self,
                    from: request,
                    context: context
                )
            } catch {
                return publicAPIErrorResponse(
                    status: .badRequest,
                    code: "invalid_request",
                    message: "The message request is invalid."
                )
            }
            let text = input.text.trimmed()
            guard !text.isEmpty else {
                return publicAPIErrorResponse(
                    status: .badRequest,
                    code: "empty_message",
                    message: "A message must contain text."
                )
            }
            do {
                let event = try await send(
                    input: input,
                    text: text,
                    conversation: conversation,
                    bridge: dependencies.webChatBridge
                )
                return try publicAPIResponse(event)
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
    let profile: TurgaiAgentProfile
    let publicID: TurgaiModels.ConversationID

    /// Who writes in it for `owner`: the signed-in account, the same person in each of its chats,
    /// or else the API client the conversation is.
    func person(for owner: ChatOwner) -> TurgaiDomain.UserID {
        switch owner {
        case .account(let id): TurgaiDomain.UserID(account: id)
        case .anonymous: TurgaiDomain.UserID(rawValue: "api:\(domainID.stableKey)")
        }
    }

    var info: TurgaiModels.Conversation {
        .init(
            id: publicID,
            botID: .init(rawValue: profile.id)
        )
    }
}

private func apiConversationID(profileID: String) -> TurgaiDomain.ConversationID {
    TurgaiDomain.ConversationID(
        channel: publicAPIChannel,
        externalAddress: .init("bot-" + profileID + "-" + UUID().uuidString)
    )
}

private func accountConversationAddress(accountID: UUID, profileID: String) -> String {
    let source = Data("\(accountID.uuidString):\(profileID)".utf8)
    let digest = SHA256.hash(data: source)
    let value = digest.hexString
    return "account-\(value)"
}

private func publicAPIConversationID(
    for domainID: TurgaiDomain.ConversationID
) -> TurgaiModels.ConversationID {
    .init(rawValue: domainID.externalAddress.rawValue)
}

private func apiConversation(
    conversationID: String?,
    botID: String?,
    profiles: TurgaiAgentProfileStore
) async -> APIConversation? {
    if let conversationID {
        return await apiConversation(from: conversationID, profiles: profiles)
    }
    let profile: TurgaiAgentProfile?
    if let botID {
        profile = await profiles.profile(id: botID)
    } else {
        profile = await profiles.defaultProfile()
    }
    guard let profile, profile.availability == .enabled else { return nil }
    let domainID = apiConversationID(profileID: profile.id)
    return APIConversation(
        domainID: domainID,
        profile: profile,
        publicID: publicAPIConversationID(for: domainID)
    )
}

private enum ChatOwner: Sendable {
    case account(UUID)
    case anonymous
}

private func chatOwner(from request: Request, auth: TurgaiAuth) async -> ChatOwner {
    guard let account = await TurgaiWebSupport.authenticatedAccount(from: request, auth: auth) else {
        return .anonymous
    }
    return .account(account.id)
}

private func chatConversation(
    owner: ChatOwner,
    conversationID: String?,
    botID: String?,
    profiles: TurgaiAgentProfileStore
) async -> APIConversation? {
    if let conversationID {
        return await apiConversation(from: conversationID, profiles: profiles)
    }

    let profile: TurgaiAgentProfile?
    if let botID {
        profile = await profiles.profile(id: botID)
    } else {
        profile = await profiles.defaultProfile()
    }
    guard let profile, profile.availability == .enabled else { return nil }

    if case .account(let accountID) = owner {
        let domainID = TurgaiDomain.ConversationID(
            channel: accountChatChannel,
            externalAddress: .init(accountConversationAddress(accountID: accountID, profileID: profile.id))
        )
        return APIConversation(
            domainID: domainID,
            profile: profile,
            publicID: publicAPIConversationID(for: domainID)
        )
    }

    let domainID = apiConversationID(profileID: profile.id)
    return APIConversation(
        domainID: domainID,
        profile: profile,
        publicID: publicAPIConversationID(for: domainID)
    )
}

private func apiConversation(
    from rawValue: String?,
    profiles: TurgaiAgentProfileStore
) async -> APIConversation? {
    guard let rawValue else { return nil }
    let decodedValue = rawValue.percentDecoded ?? rawValue

    let domainID: TurgaiDomain.ConversationID
    if let stableID = TurgaiDomain.ConversationID(stableKey: decodedValue),
        stableID.channel == publicAPIChannel
    {
        // Accept IDs created by the first public API implementation so a
        // client can continue using them after the public ID became opaque.
        domainID = stableID
    } else {
        domainID = TurgaiDomain.ConversationID(
            channel: publicAPIChannel,
            externalAddress: .init(decodedValue)
        )
    }

    let address = domainID.externalAddress.rawValue
    let prefix = "bot-"
    guard address.hasPrefix(prefix),
        address.count > prefix.count + 1 + 36
    else { return nil }
    let profileStart = address.index(address.startIndex, offsetBy: prefix.count)
    let uuidStart = address.index(address.endIndex, offsetBy: -36)
    guard address[address.index(before: uuidStart)] == "-",
        UUID(uuidString: String(address[uuidStart...])) != nil,
        let profile = await profiles.profile(
            id: String(address[profileStart..<address.index(before: uuidStart)])
        ),
        profile.availability == .enabled
    else { return nil }
    return APIConversation(
        domainID: domainID,
        profile: profile,
        publicID: publicAPIConversationID(for: domainID)
    )
}

private func publicAPIMessage(_ entry: ConversationHistoryEntry) -> TurgaiModels.Message {
    let value = entry.id.split(separator: ":").last.map(String.init) ?? entry.id
    return .init(
        id: .init(rawValue: UUID(uuidString: value) ?? UUID()),
        role: entry.role == .user ? .user : .assistant,
        text: entry.text
    )
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
    bridge: TurgaiWebChatBridge
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
                publicConversationID: conversation.publicID
            ).event
            await delivery.delivered()
            if event.type == .turnCompleted || event.type == .turnFailed {
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
                    participantID: .init(
                        channel: publicAPIChannel,
                        rawValue: conversation.domainID.stableKey
                    ),
                    userID: .init(rawValue: "api:\(conversation.domainID.stableKey)"),
                    text: text,
                    receivedAt: Date()
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
    private var activeTurns: Set<UUID> = []

    init(outbound: WebSocketOutboundWriter) {
        self.outbound = outbound
    }

    func write(_ html: String) async throws {
        try await outbound.write(.text(html))
    }

    func write(_ event: OutboundEvent) async throws {
        guard let fragment = fragment(for: event) else { return }
        try await write(fragment)
    }

    /// The HTML for `event`, or `nil` for what the web chat doesn't show, such as a turn's steps.
    private func fragment(for event: OutboundEvent) -> String? {
        switch event {
        case .reply(let reply):
            switch reply {
            case .userMessage(_, _, let messageID, let text):
                return ChatLiveFragment.accepted(
                    .init(id: .init(rawValue: messageID.rawValue), role: .user, text: text)
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
    userID: TurgaiDomain.UserID
) async throws {
    let writer = HTMLChatSocketWriter(
        outbound: outbound
    )
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
    let event: TurgaiModels.ChatEvent

    init(
        event: OutboundEvent,
        publicConversationID: TurgaiModels.ConversationID
    ) {
        switch event {
        case .reply(let reply):
            self.event = Self.replyEvent(
                reply,
                publicConversationID: publicConversationID
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
        }
    }

    private static func replyEvent(
        _ reply: ReplyEvent,
        publicConversationID: TurgaiModels.ConversationID
    ) -> TurgaiModels.ChatEvent {
        switch reply {
        case .userMessage(_, let turnID, let messageID, let text):
            return .init(
                payload: .messageAccepted(
                    conversationID: publicConversationID,
                    turnID: .init(rawValue: turnID.rawValue),
                    message: .init(
                        id: .init(rawValue: messageID.rawValue),
                        role: .user,
                        text: text
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
                        text: text
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
                        text: text
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
