import Elementary
import Hummingbird
import HummingbirdElementary
import HummingbirdWebSocket
import TurgaiApplication
import TurgaiTelegram

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

extension TurgaiMainWebApp {
    func registerChannelRoutes(on router: Router<BasicWebSocketRequestContext>, dependencies: TurgaiRouteDependencies) {
        registerChannels(on: router.group("channels"), dependencies: dependencies)
    }

    /// The channels: adding one, changing it, and removing it.
    private func registerChannels(
        on channels: RouterGroup<BasicWebSocketRequestContext>, dependencies: TurgaiRouteDependencies
    ) {
        let auth = dependencies.auth
        let channelSecrets = dependencies.channelSecrets
        let agentProfiles = dependencies.agentProfiles
        let webChatBridge = dependencies.webChatBridge
        channels.get { request, context in
            guard let user = await TurgaiWebSupport.authenticatedAdminUser(from: request, auth: auth) else {
                return TurgaiWebSupport.redirect(to: try await auth.hasAdmin() ? "/login" : "/onboarding")
            }
            var items: [ChannelListItem] = []
            for id in (try? await webChatBridge.channelIDs()) ?? [] {
                guard let state = try? await webChatBridge.channelState(for: id),
                    case .active(let configuration, _) = state
                else {
                    continue
                }
                var botName: String?
                if let binding = configuration.agentRouting.profileID {
                    botName = try await agentProfiles.profile(id: binding)?.name
                }
                items.append(
                    ChannelListItem(
                        id: configuration.id,
                        label: configuration.label,
                        enabled: configuration.enabled,
                        hasToken: try await channelSecrets.hasToken(for: configuration.id),
                        botName: botName
                    )
                )
            }
            return HTMLResponse {
                ChannelsPage(user: user, channels: items)
            }.response(from: request, context: context)
        }

        channels.get("new") { request, context in
            guard let user = await TurgaiWebSupport.authenticatedAdminUser(from: request, auth: auth) else {
                return TurgaiWebSupport.redirect(to: try await auth.hasAdmin() ? "/login" : "/onboarding")
            }
            return HTMLResponse {
                NewChannelPage(user: user)
            }.response(from: request, context: context)
        }

        channels.post("create") { request, context in
            guard let user = await TurgaiWebSupport.authenticatedAdminUser(from: request, auth: auth) else {
                return TurgaiWebSupport.redirect(to: try await auth.hasAdmin() ? "/login" : "/onboarding")
            }
            let form = try await TurgaiWebSupport.decodeForm(from: request, context: context)
            let values = ChannelCreateFormValues(form: form)
            do {
                guard values.kind == "telegram" else {
                    throw ChannelFormError.unsupportedChannel
                }
                let proposed = ChannelConfiguration<TelegramProvider>(
                    id: UUID(),
                    label: values.label,
                    enabled: false,
                    agentRouting: .defaultProfile,
                    provider: TelegramChannelConfig(chatIDs: [])
                )
                try await webChatBridge.configureChannel(proposed)
                let state = try await webChatBridge.channelState(for: proposed)
                guard case .active(let configuration, _) = state else {
                    throw TurgaiChannelError.unknownChannel(proposed.id)
                }
                return TurgaiWebSupport.redirect(to: "/channels/\(configuration.id.uuidString)")
            } catch {
                return HTMLResponse {
                    NewChannelPage(user: user, error: TurgaiWebSupport.channelErrorMessage(error))
                }.response(from: request, context: context)
            }
        }

        channels.get(":id") { request, context in
            guard let user = await TurgaiWebSupport.authenticatedAdminUser(from: request, auth: auth) else {
                return TurgaiWebSupport.redirect(to: try await auth.hasAdmin() ? "/login" : "/onboarding")
            }
            guard let id = Self.channelID(from: context),
                (try? await webChatBridge.channelIDs().contains(id)) == true
            else {
                return TurgaiWebSupport.redirect(to: "/channels")
            }
            let state: ChannelState<TelegramProvider>
            do {
                state = try await webChatBridge.channelState(for: id)
            } catch {
                return TurgaiWebSupport.redirect(to: "/channels")
            }
            guard case .active(let configuration, _) = state else {
                return TurgaiWebSupport.redirect(to: "/channels")
            }
            let draft = ChannelDraft(configuration, hasToken: try await channelSecrets.hasToken(for: configuration.id))
            let bots = try await Self.botOptions(agentProfiles: agentProfiles)
            return HTMLResponse {
                ChannelEditPage(user: user, channel: draft, bots: bots)
            }.response(from: request, context: context)
        }

        channels.post("update") { request, context in
            guard let user = await TurgaiWebSupport.authenticatedAdminUser(from: request, auth: auth) else {
                return TurgaiWebSupport.redirect(to: try await auth.hasAdmin() ? "/login" : "/onboarding")
            }
            let form = try await TurgaiWebSupport.decodeForm(from: request, context: context)
            guard let id = UUID(uuidString: form["id"]?.first ?? ""),
                (try? await webChatBridge.channelIDs().contains(id)) == true,
                case .active(let existing, _)? = try? await webChatBridge.channelState(for: id)
            else {
                return TurgaiWebSupport.redirect(to: "/channels")
            }
            let draft = ChannelDraft(
                form: form, over: ChannelDraft(existing, hasToken: try await channelSecrets.hasToken(for: id)))
            do {
                let chatIDs = try OnboardingInput.chatIDs(from: draft.chatIDs)
                if case .profile(let binding) = draft.routing {
                    // The runtime would fall back to default routing for an
                    // unusable binding; reject here instead so the form never
                    // silently pretends a binding it cannot honor.
                    guard let profile = try await agentProfiles.profile(id: binding),
                        profile.availability == .enabled
                    else {
                        throw ChannelFormError.unknownBot
                    }
                }
                let newToken = draft.token.isEmpty ? nil : draft.token
                if let newToken {
                    // Validate the credential before persisting either part of
                    // the form. Credential storage and the channel journal are
                    // separate owners, so these writes cannot be atomic.
                    try await TelegramAPIClient.live(token: newToken).validateToken()
                }
                let updated = ChannelConfiguration<TelegramProvider>(
                    id: existing.id,
                    label: draft.label,
                    enabled: draft.enabled,
                    agentRouting: draft.routing,
                    provider: TelegramChannelConfig(chatIDs: chatIDs)
                )
                let previousToken: String?
                if newToken != nil {
                    previousToken = try await channelSecrets.token(for: id)
                } else {
                    previousToken = nil
                }
                do {
                    if let newToken {
                        try await channelSecrets.setToken(for: id, token: newToken)
                    }
                    try await webChatBridge.configureChannel(updated)
                } catch {
                    if newToken != nil {
                        if let previousToken {
                            try? await channelSecrets.setToken(for: id, token: previousToken)
                        } else {
                            try? await channelSecrets.remove(for: id)
                        }
                    }
                    throw error
                }
                return TurgaiWebSupport.redirect(to: "/channels/\(id.uuidString)")
            } catch {
                var shown = draft
                shown.hasToken = try await channelSecrets.hasToken(for: id)
                shown.token = ""
                let bots = try await Self.botOptions(agentProfiles: agentProfiles)
                return HTMLResponse {
                    ChannelEditPage(
                        user: user,
                        channel: shown,
                        bots: bots,
                        error: TurgaiWebSupport.channelErrorMessage(error)
                    )
                }.response(from: request, context: context)
            }
        }

        channels.post("delete") { request, context in
            guard await TurgaiWebSupport.authenticatedAdminUser(from: request, auth: auth) != nil else {
                return TurgaiWebSupport.redirect(to: try await auth.hasAdmin() ? "/login" : "/onboarding")
            }
            let form = try await TurgaiWebSupport.decodeForm(from: request, context: context)
            if let id = UUID(uuidString: form["id"]?.first ?? "") {
                do {
                    try await webChatBridge.deleteChannel(id: id)
                    try await channelSecrets.remove(for: id)
                } catch {
                    // The journal remains discoverable if deletion did not
                    // commit, so the user can retry.
                }
            }
            return TurgaiWebSupport.redirect(to: "/channels")
        }
    }

    private static func channelID(from context: BasicWebSocketRequestContext) -> UUID? {
        guard let rawID = context.parameters.get("id"),
            let id = UUID(uuidString: rawID)
        else { return nil }
        return id
    }

    private static func botOptions(
        agentProfiles: TurgaiAgentProfileStore
    ) async throws -> [ChannelBotOption] {
        try await agentProfiles.profiles()
            .filter { $0.availability == .enabled }
            .map { ChannelBotOption(id: $0.id, name: $0.name) }
    }
}
