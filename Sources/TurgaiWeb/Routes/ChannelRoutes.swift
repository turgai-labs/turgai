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
        let auth = dependencies.auth
        let channelSecrets = dependencies.channelSecrets
        let agentProfiles = dependencies.agentProfiles
        let webChatBridge = dependencies.webChatBridge

        router.get("/channels") { request, context in
            guard let user = await TurgaiWebSupport.authenticatedAdminUser(from: request, auth: auth) else {
                return TurgaiWebSupport.redirect(to: await auth.hasAdmin() ? "/login" : "/onboarding")
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
                    botName = await agentProfiles.profile(id: binding)?.name
                }
                items.append(
                    ChannelListItem(
                        id: configuration.id,
                        label: configuration.label,
                        enabled: configuration.enabled,
                        hasToken: await channelSecrets.hasToken(for: configuration.id),
                        botName: botName
                    )
                )
            }
            return HTMLResponse {
                ChannelsPage(user: user, channels: items)
            }.response(from: request, context: context)
        }
        router.get("/channels/new") { request, context in
            guard let user = await TurgaiWebSupport.authenticatedAdminUser(from: request, auth: auth) else {
                return TurgaiWebSupport.redirect(to: await auth.hasAdmin() ? "/login" : "/onboarding")
            }
            return HTMLResponse {
                NewChannelPage(user: user)
            }.response(from: request, context: context)
        }
        router.post("/channels/create") { request, context in
            guard let user = await TurgaiWebSupport.authenticatedAdminUser(from: request, auth: auth) else {
                return TurgaiWebSupport.redirect(to: await auth.hasAdmin() ? "/login" : "/onboarding")
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
                try await webChatBridge.configureChannel(
                    proposed,
                    runtimeChange: .configuration
                )
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
        router.get("/channels/:id") { request, context in
            guard let user = await TurgaiWebSupport.authenticatedAdminUser(from: request, auth: auth) else {
                return TurgaiWebSupport.redirect(to: await auth.hasAdmin() ? "/login" : "/onboarding")
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
            let editItem = await Self.editItem(for: configuration, secrets: channelSecrets)
            let bots = await Self.botOptions(agentProfiles: agentProfiles)
            return HTMLResponse {
                ChannelEditPage(user: user, channel: editItem, bots: bots)
            }.response(from: request, context: context)
        }
        router.post("/channels/update") { request, context in
            guard let user = await TurgaiWebSupport.authenticatedAdminUser(from: request, auth: auth) else {
                return TurgaiWebSupport.redirect(to: await auth.hasAdmin() ? "/login" : "/onboarding")
            }
            let form = try await TurgaiWebSupport.decodeForm(from: request, context: context)
            let values = ChannelUpdateFormValues(form: form)
            guard let id = UUID(uuidString: values.id),
                (try? await webChatBridge.channelIDs().contains(id)) == true
            else {
                return TurgaiWebSupport.redirect(to: "/channels")
            }
            do {
                let existingState = try await webChatBridge.channelState(for: id)
                guard case .active(let existing, _) = existingState else {
                    return TurgaiWebSupport.redirect(to: "/channels")
                }
                let chatIDs = try OnboardingInput.chatIDs(from: values.chatIDs)
                if let binding = values.agentProfileID {
                    // The runtime would fall back to default routing for an
                    // unusable binding; reject here instead so the form never
                    // silently pretends a binding it cannot honor.
                    guard let profile = await agentProfiles.profile(id: binding),
                        profile.availability == .enabled
                    else {
                        throw ChannelFormError.unknownBot
                    }
                }
                let token = values.token?.trimmingCharacters(in: .whitespacesAndNewlines)
                let newToken = (token?.isEmpty == false) ? token : nil
                if let newToken {
                    // Validate the credential before persisting either part of
                    // the form. Credential storage and the channel journal are
                    // separate owners, so these writes cannot be atomic.
                    try await TelegramAPIClient.live(token: newToken).validateToken()
                }
                let updated = ChannelConfiguration<TelegramProvider>(
                    id: existing.id,
                    label: values.label,
                    enabled: values.enabled,
                    agentRouting: values.agentProfileID.map(ChannelAgentRouting.profile)
                        ?? .defaultProfile,
                    provider: TelegramChannelConfig(chatIDs: chatIDs)
                )
                let previousToken: String?
                if newToken != nil {
                    previousToken = await channelSecrets.token(for: id)
                } else {
                    previousToken = nil
                }
                do {
                    if let newToken {
                        try await channelSecrets.setToken(for: id, token: newToken)
                    }
                    try await webChatBridge.configureChannel(
                        updated,
                        runtimeChange: newToken == nil ? .configuration : .providerCredentials
                    )
                } catch {
                    if newToken != nil {
                        if let previousToken {
                            try? await channelSecrets.setToken(for: id, token: previousToken)
                        } else {
                            try? await channelSecrets.remove(for: id)
                        }
                        // A rejected journal write can leave the current
                        // runtime stopped. Rebuild it against the credential
                        // that belonged to the accepted configuration.
                        try? await webChatBridge.configureChannel(
                            existing,
                            runtimeChange: .providerCredentials
                        )
                    }
                    throw error
                }
                return TurgaiWebSupport.redirect(to: "/channels/\(id.uuidString)")
            } catch {
                let hasToken = await channelSecrets.hasToken(for: id)
                let bots = await Self.botOptions(agentProfiles: agentProfiles)
                return HTMLResponse {
                    ChannelEditPage(
                        user: user,
                        channel: ChannelEditItem(
                            id: id,
                            label: values.label,
                            enabled: values.enabled,
                            chatIDs: (try? OnboardingInput.chatIDs(from: values.chatIDs)) ?? [],
                            hasToken: hasToken,
                            agentProfileID: values.agentProfileID
                        ),
                        bots: bots,
                        error: TurgaiWebSupport.channelErrorMessage(error)
                    )
                }.response(from: request, context: context)
            }
        }
        router.post("/channels/delete") { request, context in
            guard await TurgaiWebSupport.authenticatedAdminUser(from: request, auth: auth) != nil else {
                return TurgaiWebSupport.redirect(to: await auth.hasAdmin() ? "/login" : "/onboarding")
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

    private static func editItem(
        for configuration: ChannelConfiguration<TelegramProvider>,
        secrets: ChannelSecretStore
    ) async -> ChannelEditItem {
        ChannelEditItem(
            id: configuration.id,
            label: configuration.label,
            enabled: configuration.enabled,
            chatIDs: configuration.provider.chatIDs,
            hasToken: await secrets.hasToken(for: configuration.id),
            agentProfileID: configuration.agentRouting.profileID
        )
    }

    private static func botOptions(
        agentProfiles: TurgaiAgentProfileStore
    ) async -> [ChannelBotOption] {
        await agentProfiles.profiles()
            .filter { $0.availability == .enabled }
            .map { ChannelBotOption(id: $0.id, name: $0.name) }
    }
}
