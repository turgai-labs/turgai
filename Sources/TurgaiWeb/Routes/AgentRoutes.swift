import Elementary
import Hail
import Hummingbird
import HummingbirdElementary
import HummingbirdWebSocket
import Logging
import NIOCore
import TurgaiApplication
import TurgaiDomain
import TurgaiHail
import TurgaiPersistence
import TurgaiTelegram

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

private let webChatLogger = Logger(label: "turgai.web.chat")

extension TurgaiMainWebApp {
    func registerAgentRoutes(on router: Router<BasicWebSocketRequestContext>, dependencies: TurgaiRouteDependencies) {
        let auth = dependencies.auth
        let agentProfiles = dependencies.agentProfiles
        let runtimeSnapshots = dependencies.runtimeSnapshots
        let webChatBridge = dependencies.webChatBridge
        router.get("/chat") { request, context in
            guard let profile = await agentProfiles.defaultProfile() else {
                return TurgaiWebSupport.redirect(to: "/onboarding")
            }
            guard let account = await TurgaiWebSupport.authenticatedAccount(from: request, auth: auth) else {
                return TurgaiWebSupport.redirect(to: await auth.hasAdmin() ? "/login" : "/onboarding")
            }
            let identity = account.id.uuidString
            let conversationID = webConversationID(profileID: profile.id, identity: identity)
            let history: [ConversationHistoryEntry]
            do {
                history = try await webChatBridge.conversationHistory(
                    for: conversationID,
                    role: .profile(profile.id)
                )
                webChatLogger.info(
                    "Loaded web chat history",
                    metadata: [
                        "conversationID": .string(conversationID.stableKey),
                        "profileID": .string(profile.id),
                        "messageCount": .string("\(history.count)"),
                    ]
                )
            } catch {
                webChatLogger.error(
                    "Could not load web chat history",
                    metadata: [
                        "conversationID": .string(conversationID.stableKey),
                        "profileID": .string(profile.id),
                        "error": .string(String(describing: error)),
                    ]
                )
                history = []
            }
            let response = HTMLResponse {
                ChatPage(
                    user: TurgaiWebSupport.userInfo(from: account),
                    profile: profile,
                    history: history,
                    presentation: .publicChat
                )
            }.response(from: request, context: context)
            return response
        }
        router.ws("/chat/live") { _, _ in
            .upgrade([:])
        } onUpgrade: { inbound, outbound, context in
            guard let account = await TurgaiWebSupport.authenticatedAccount(from: context.request, auth: auth) else {
                try await outbound.close(.policyViolation, reason: "Sign in to chat")
                return
            }
            guard let profile = await agentProfiles.defaultProfile() else {
                try await outbound.close(.policyViolation, reason: "No default bot configured")
                return
            }
            let identity = account.id.uuidString
            let conversationID = webConversationID(profileID: profile.id, identity: identity)
            let participantID = ParticipantID(
                channel: ChannelID("web"),
                rawValue: identity
            )
            let userID = TurgaiDomain.UserID(rawValue: "web:\(identity)")
            let session: TurgaiConnections.WebSession
            do {
                session = try await webChatBridge.openSession(id: WebSessionID())
            } catch {
                try await outbound.close(.policyViolation, reason: "Chat runtime unavailable")
                return
            }

            let connectReceipt = ConversationInputReceipt()
            await session.input.send(
                ConversationInputDelivery(
                    input: .connect(conversationID),
                    receipt: connectReceipt
                )
            )
            guard await connectReceipt.wait() else {
                session.input.finish()
                try await outbound.close(.policyViolation, reason: "Could not open conversation")
                return
            }

            do {
                let socketWriter = WebChatSocketWriter(outbound: outbound)
                let history = try await webChatBridge.conversationHistory(
                    for: conversationID,
                    role: .profile(profile.id)
                )
                try await socketWriter.write(.history(history))
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask {
                        for try await input in inbound.messages(maxSize: 1_000_000) {
                            guard case .text(let text) = input,
                                let data = text.data(using: .utf8),
                                let command = try? JSONDecoder().decode(WebChatCommand.self, from: data),
                                let messageText = command.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                                !messageText.isEmpty
                            else { continue }
                            try await socketWriter.write(.userMessage(messageText))
                            let message = InboundMessage(
                                conversationID: conversationID,
                                participantID: participantID,
                                userID: userID,
                                author: MessageAuthor(displayName: account.username),
                                text: messageText,
                                receivedAt: Date()
                            )
                            let receipt = ConversationInputReceipt()
                            await session.input.send(
                                ConversationInputDelivery(
                                    input: .message(message, turnID: TurnID()),
                                    receipt: receipt
                                )
                            )
                            _ = await receipt.wait()
                        }
                    }
                    group.addTask {
                        for await delivery in session.output {
                            try await socketWriter.write(WebChatEvent(outbound: delivery.event))
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
        router.get("/chat/:id") { request, context in
            guard let user = await TurgaiWebSupport.authenticatedDashboardUser(from: request, auth: auth) else {
                return TurgaiWebSupport.redirect(to: await auth.hasAdmin() ? "/login" : "/onboarding")
            }
            guard let id = context.parameters.get("id"),
                let profile = await agentProfiles.profile(id: id)
            else {
                return TurgaiWebSupport.redirect(to: "/")
            }
            let conversationID = webConversationID(profileID: profile.id, identity: user.id.uuidString)
            let history: [ConversationHistoryEntry]
            do {
                history = try await webChatBridge.conversationHistory(
                    for: conversationID,
                    role: .profile(profile.id)
                )
            } catch {
                webChatLogger.error(
                    "Could not load web chat history",
                    metadata: [
                        "conversationID": .string(conversationID.stableKey),
                        "profileID": .string(profile.id),
                        "error": .string(String(describing: error)),
                    ]
                )
                history = []
            }
            return HTMLResponse {
                ChatPage(user: user, profile: profile, history: history)
            }.response(from: request, context: context)
        }
        router.ws("/chat/:id/live") { request, context in
            guard await TurgaiWebSupport.authenticatedDashboardUser(from: request, auth: auth) != nil,
                context.parameters.get("id") != nil
            else {
                return .dontUpgrade
            }
            return .upgrade([:])
        } onUpgrade: { inbound, outbound, context in
            guard
                let user = await TurgaiWebSupport.authenticatedDashboardUser(
                    from: context.request,
                    auth: auth
                ), let profileID = context.request.uri.path.split(separator: "/").dropFirst().first,
                let profile = await agentProfiles.profile(id: String(profileID))
            else {
                try await outbound.close(.policyViolation, reason: "Unauthorized")
                return
            }

            let conversationID = webConversationID(profileID: profile.id, identity: user.id.uuidString)
            let participantID = ParticipantID(
                channel: ChannelID("web"),
                rawValue: user.id.uuidString
            )
            let userID = TurgaiDomain.UserID(rawValue: "web:\(user.id.uuidString)")
            let session: TurgaiConnections.WebSession
            do {
                session = try await webChatBridge.openSession(id: WebSessionID())
            } catch {
                try await outbound.close(.policyViolation, reason: "Chat runtime unavailable")
                return
            }

            let connectReceipt = ConversationInputReceipt()
            await session.input.send(
                ConversationInputDelivery(
                    input: .connect(conversationID),
                    receipt: connectReceipt
                )
            )
            guard await connectReceipt.wait() else {
                session.input.finish()
                try await outbound.close(.policyViolation, reason: "Could not open conversation")
                return
            }

            do {
                let socketWriter = WebChatSocketWriter(outbound: outbound)
                let history = try await webChatBridge.conversationHistory(
                    for: conversationID,
                    role: .profile(profile.id)
                )
                try await socketWriter.write(.history(history))
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask {
                        for try await input in inbound.messages(maxSize: 1_000_000) {
                            guard case .text(let text) = input,
                                let data = text.data(using: .utf8),
                                let command = try? JSONDecoder().decode(WebChatCommand.self, from: data),
                                let messageText = command.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                                !messageText.isEmpty
                            else { continue }
                            try await socketWriter.write(.userMessage(messageText))
                            let message = InboundMessage(
                                conversationID: conversationID,
                                participantID: participantID,
                                userID: userID,
                                author: MessageAuthor(displayName: user.username),
                                text: messageText,
                                receivedAt: Date()
                            )
                            let receipt = ConversationInputReceipt()
                            await session.input.send(
                                ConversationInputDelivery(
                                    input: .message(message, turnID: TurnID()),
                                    receipt: receipt
                                )
                            )
                            _ = await receipt.wait()
                        }
                    }
                    group.addTask {
                        for await delivery in session.output {
                            try await socketWriter.write(WebChatEvent(outbound: delivery.event))
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
        router.get("/agents/new") { request, context in
            guard let user = await TurgaiWebSupport.authenticatedAdminUser(from: request, auth: auth) else {
                return TurgaiWebSupport.redirect(to: await auth.hasAdmin() ? "/login" : "/onboarding")
            }
            let profiles = await agentProfiles.profiles()
            let modelCatalog = await TurgaiWebSupport.modelCatalog(for: profiles)
            return HTMLResponse {
                NewAgentPage(
                    user: user,
                    modelCatalog: modelCatalog
                )
            }.response(from: request, context: context)
        }
        router.get("/agents/:id") { request, context in
            guard let user = await TurgaiWebSupport.authenticatedDashboardUser(from: request, auth: auth) else {
                return TurgaiWebSupport.redirect(to: await auth.hasAdmin() ? "/login" : "/onboarding")
            }
            guard let id = context.parameters.get("id"),
                let profile = await agentProfiles.profile(id: id)
            else {
                return TurgaiWebSupport.redirect(to: "/")
            }
            let profiles = await agentProfiles.profiles()
            let modelCatalog = await TurgaiWebSupport.modelCatalog(for: profiles)
            let runtime = await runtimeSnapshots().filter { $0.profileID == profile.id }
            let placement: AgentDetailPage.Placement =
                await agentProfiles.isDefaultProfile(id: profile.id) ? .default : .additional
            return HTMLResponse {
                AgentDetailPage(
                    user: user,
                    profile: profile,
                    modelCatalog: modelCatalog,
                    runtime: runtime,
                    placement: placement
                )
            }.response(from: request, context: context)
        }
        router.post("/agents/update") { request, context in
            guard let user = await TurgaiWebSupport.authenticatedAdminUser(from: request, auth: auth) else {
                return TurgaiWebSupport.redirect(to: await auth.hasAdmin() ? "/login" : "/onboarding")
            }
            let form = try await TurgaiWebSupport.decodeForm(from: request, context: context)
            let id = form["id"]?.first ?? ""
            guard let existingProfile = await agentProfiles.profile(id: id) else {
                return TurgaiWebSupport.redirect(to: "/")
            }
            do {
                let values = BotFormValues(form: form)
                var profile = existingProfile
                profile.name = values.name
                let modelValues = ModelFormValues(form: form)
                let model = try OnboardingInput.model(from: modelValues)
                profile.model = model
                profile.ollamaBaseURL = try OnboardingInput.ollamaBaseURL(from: modelValues, for: model)
                profile.contextWindow = try OnboardingInput.positiveInteger(
                    values.contextWindow,
                    field: "context window"
                )
                profile.persona = values.persona
                profile.instructions = values.instructions
                profile.telegramChatIDs = try OnboardingInput.chatIDs(from: values.telegramChatIDs)
                try await agentProfiles.update(profile)
                return TurgaiWebSupport.redirect(to: "/agents/\(profile.id)")
            } catch {
                let profiles = await agentProfiles.profiles()
                let modelCatalog = await TurgaiWebSupport.modelCatalog(for: profiles)
                let runtime = await runtimeSnapshots().filter { $0.profileID == existingProfile.id }
                let placement: AgentDetailPage.Placement =
                    await agentProfiles.isDefaultProfile(id: existingProfile.id) ? .default : .additional
                return HTMLResponse {
                    AgentDetailPage(
                        user: user,
                        profile: existingProfile,
                        modelCatalog: modelCatalog,
                        runtime: runtime,
                        placement: placement,
                        error: TurgaiWebSupport.profileErrorMessage(error)
                    )
                }.response(from: request, context: context)
            }
        }
        router.post("/agents/default") { request, context in
            guard await TurgaiWebSupport.authenticatedAdminUser(from: request, auth: auth) != nil else {
                return TurgaiWebSupport.redirect(to: await auth.hasAdmin() ? "/login" : "/onboarding")
            }
            let form = try await TurgaiWebSupport.decodeForm(from: request, context: context)
            let id = form["id"]?.first ?? ""
            do {
                try await agentProfiles.setDefaultProfile(id: id)
                return TurgaiWebSupport.redirect(to: "/agents/\(id)")
            } catch {
                return TurgaiWebSupport.redirect(to: "/agents/\(id)")
            }
        }
        router.post("/agents/create") { request, context in
            guard let user = await TurgaiWebSupport.authenticatedAdminUser(from: request, auth: auth) else {
                return TurgaiWebSupport.redirect(to: await auth.hasAdmin() ? "/login" : "/onboarding")
            }
            let form = try await TurgaiWebSupport.decodeForm(from: request, context: context)
            do {
                let values = BotFormValues(form: form)
                let modelValues = ModelFormValues(form: form)
                let model = try OnboardingInput.model(from: modelValues)
                let ollamaBaseURL = try OnboardingInput.ollamaBaseURL(from: modelValues, for: model)
                let contextWindow = try OnboardingInput.positiveInteger(
                    values.contextWindow,
                    field: "context window"
                )
                let profile = try await agentProfiles.create(
                    name: values.name,
                    model: model,
                    ollamaBaseURL: ollamaBaseURL,
                    contextWindow: contextWindow,
                    persona: values.persona,
                    instructions: values.instructions,
                    telegramChatIDs: try OnboardingInput.chatIDs(from: values.telegramChatIDs)
                )
                return TurgaiWebSupport.redirect(to: "/agents/\(profile.id)")
            } catch {
                let profiles = await agentProfiles.profiles()
                let modelCatalog = await TurgaiWebSupport.modelCatalog(for: profiles)
                return HTMLResponse {
                    NewAgentPage(
                        user: user,
                        modelCatalog: modelCatalog,
                        error: TurgaiWebSupport.profileErrorMessage(error)
                    )
                }.response(from: request, context: context)
            }
        }
        router.post("/agents/delete") { request, context in
            guard let user = await TurgaiWebSupport.authenticatedAdminUser(from: request, auth: auth) else {
                return TurgaiWebSupport.redirect(to: await auth.hasAdmin() ? "/login" : "/onboarding")
            }
            let form = try await TurgaiWebSupport.decodeForm(from: request, context: context)
            let id = form["id"]?.first ?? ""
            guard let profile = await agentProfiles.profile(id: id) else {
                return TurgaiWebSupport.redirect(to: "/")
            }
            do {
                try await agentProfiles.delete(id: id)
                return TurgaiWebSupport.redirect(to: "/")
            } catch {
                let profiles = await agentProfiles.profiles()
                let modelCatalog = await TurgaiWebSupport.modelCatalog(for: profiles)
                let runtime = await runtimeSnapshots().filter { $0.profileID == profile.id }
                let placement: AgentDetailPage.Placement =
                    await agentProfiles.isDefaultProfile(id: profile.id) ? .default : .additional
                return HTMLResponse {
                    AgentDetailPage(
                        user: user,
                        profile: profile,
                        modelCatalog: modelCatalog,
                        runtime: runtime,
                        placement: placement,
                        error: TurgaiWebSupport.profileErrorMessage(error)
                    )
                }.response(from: request, context: context)
            }
        }
    }
}

private func webConversationID(profileID: String, identity: String) -> ConversationID {
    ConversationID(
        channel: ChannelID("web"),
        externalAddress: ExternalConversationAddress(
            "\(profileID):\(identity)"
        )
    )
}

private struct WebChatCommand: Decodable {
    let text: String?
}

private actor WebChatSocketWriter {
    private let outbound: WebSocketOutboundWriter

    init(outbound: WebSocketOutboundWriter) {
        self.outbound = outbound
    }

    func write(_ event: WebChatEvent) async throws {
        let data = try JSONEncoder().encode(event)
        guard let text = String(data: data, encoding: .utf8) else {
            throw WebChatEventError.encodingFailed
        }
        try await outbound.write(.text(text))
    }
}

private enum WebChatEventError: Error {
    case encodingFailed
}

private struct WebChatEvent: Encodable {
    enum Kind: String, Encodable {
        case history
        case user
        case started
        case partial
        case finished
        case failed
        case progress
        case notice
    }

    let type: Kind
    let html: String?
    let messages: [WebChatHistoryMessage]?

    static func history(_ messages: [ConversationHistoryEntry]) -> Self {
        Self(
            type: .history,
            html: nil,
            messages: messages.compactMap(WebChatHistoryMessage.init)
        )
    }

    static func userMessage(_ text: String) -> Self {
        Self(type: .user, text: text)
    }

    init(outbound: OutboundEvent) {
        switch outbound {
        case .reply(let event):
            switch event {
            case .started: self.init(type: .started, text: nil)
            case .partial(_, _, let text): self.init(type: .partial, text: text)
            case .finished(_, _, let text): self.init(type: .finished, text: text)
            case .failed(_, _, let message): self.init(type: .failed, text: message)
            case .phase, .keepAlive, .completed: self.init(type: .progress, text: nil)
            }
        case .notice(_, _, let text), .noticeWithActions(_, _, let text, _):
            self.init(type: .notice, text: text)
        case .reset:
            self.init(type: .notice, text: "Conversation reset.")
        }
    }

    private init(type: Kind, text: String?) {
        self.type = type
        self.html = text.map(MarkdownRenderer.html(from:))
        self.messages = nil
    }

    private init(type: Kind, html: String?, messages: [WebChatHistoryMessage]?) {
        self.type = type
        self.html = html
        self.messages = messages
    }
}

private struct WebChatHistoryMessage: Encodable {
    let role: ConversationHistoryRole
    let html: String

    init(entry: ConversationHistoryEntry) {
        self.role = entry.role
        self.html = MarkdownRenderer.html(from: entry.text)
    }
}
