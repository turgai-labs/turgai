import Elementary
import Hummingbird
import HummingbirdElementary
import HummingbirdWebSocket
import TurgaiApplication
import TurgaiDomain
import TurgaiHail

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

extension TurgaiMainWebApp {
    func registerAgentRoutes(on router: Router<BasicWebSocketRequestContext>, dependencies: TurgaiRouteDependencies) {
        registerChat(on: router.group("chat"), dependencies: dependencies)
        registerAgents(on: router.group("agents"), dependencies: dependencies)
    }

    /// Chatting with a bot: in the conversation the address names; without one, in the person's
    /// latest, with the default bot or the one chosen, or a new one when they have none.
    private func registerChat(
        on chat: RouterGroup<BasicWebSocketRequestContext>, dependencies: TurgaiRouteDependencies
    ) {
        let auth = dependencies.auth
        let agentProfiles = dependencies.agentProfiles
        let bridge = dependencies.webChatBridge
        /// The page of the conversation `request` names, as `user` reads it, with `presentation`;
        /// without one, a redirect to `path` naming the conversation to show: their latest answered
        /// by `bot`, or by any bot when none is chosen, or else a new one with `bot`, or the
        /// default bot.
        @Sendable func page(
            _ request: Request, _ context: BasicWebSocketRequestContext, for user: AuthenticatedUser,
            bot: TurgaiAgentProfile?, at path: String, as presentation: ChatPage.Presentation
        ) async throws -> Response {
            let person = TurgaiDomain.UserID.account(user.id)
            guard let written = request.uri.queryParameters["conversation"].map(String.init) else {
                let latest = try await bridge.conversations(of: person).first { listing in
                    listing.id.channel == turgaiChannel && (bot == nil || listing.agent.rawValue == bot?.id)
                }
                if let latest {
                    return TurgaiWebSupport.redirect(to: "\(path)?conversation=\(latest.id.externalAddress.rawValue)")
                }
                let chosen = if let bot { bot } else { try await agentProfiles.defaultProfile() }
                guard let profile = chosen else { return TurgaiWebSupport.redirect(to: "/onboarding") }
                let started = TurgaiDomain.ConversationID(
                    channel: turgaiChannel, externalAddress: .init(UUID().uuidString))
                try await bridge.startConversation(started, in: nil, agent: AgentProfileID(profile.id), by: person)
                return TurgaiWebSupport.redirect(to: "\(path)?conversation=\(started.externalAddress.rawValue)")
            }
            guard let minted = UUID(uuidString: written) else { return TurgaiWebSupport.redirect(to: path) }
            let conversation = TurgaiDomain.ConversationID(
                channel: turgaiChannel, externalAddress: .init(minted.uuidString))
            let outline: ConversationOutline
            do {
                outline = try await bridge.conversation(conversation, readBy: person)
            } catch is ConversationRefusal {
                return TurgaiWebSupport.redirect(to: path)
            }
            guard let agent = outline.agent, let profile = try await agentProfiles.profile(id: agent.rawValue) else {
                return TurgaiWebSupport.redirect(to: "/")
            }
            return HTMLResponse {
                ChatPage(
                    user: user, profile: profile, conversationID: minted.uuidString, presentation: presentation)
            }.response(from: request, context: context)
        }

        chat.get { request, context in
            guard let account = await TurgaiWebSupport.authenticatedAccount(from: request, auth: auth) else {
                return TurgaiWebSupport.redirect(to: try await auth.hasAdmin() ? "/login" : "/onboarding")
            }
            return try await page(
                request, context, for: TurgaiWebSupport.userInfo(from: account), bot: nil, at: "/chat",
                as: .publicChat)
        }

        chat.get(":id") { request, context in
            guard let user = await TurgaiWebSupport.authenticatedDashboardUser(from: request, auth: auth) else {
                return TurgaiWebSupport.redirect(to: try await auth.hasAdmin() ? "/login" : "/onboarding")
            }
            guard let id = context.parameters.get("id"),
                let profile = try await agentProfiles.profile(id: id)
            else {
                return TurgaiWebSupport.redirect(to: "/")
            }
            return try await page(request, context, for: user, bot: profile, at: "/chat/\(id)", as: .dashboard)
        }
    }

    /// The bots: making one, looking at one, changing it, and removing it.
    private func registerAgents(
        on agents: RouterGroup<BasicWebSocketRequestContext>, dependencies: TurgaiRouteDependencies
    ) {
        let auth = dependencies.auth
        let agentProfiles = dependencies.agentProfiles
        let agentCredentials = dependencies.agentCredentials
        let requestLimits = dependencies.requestLimits
        /// The limit of `profile`'s provider account, if it has one.
        @Sendable func requestLimit(of profile: TurgaiAgentProfile) async throws -> Int? {
            guard let account = profile.providerConfiguration.account(for: profile.model) else { return nil }
            return try await requestLimits.limit(for: account)
        }
        /// Sets the limit `draft` gives for `profile`'s provider account: empty lifts it.
        @Sendable func saveRequestLimit(of draft: AgentDraft, for profile: TurgaiAgentProfile) async throws {
            guard let account = profile.providerConfiguration.account(for: profile.model) else { return }
            try await requestLimits.setLimit(Int(draft.settings.requestLimit), for: account)
        }
        let runtimeSnapshots = dependencies.runtimeSnapshots
        agents.get("new") { request, context in
            guard let user = await TurgaiWebSupport.authenticatedAdminUser(from: request, auth: auth) else {
                return TurgaiWebSupport.redirect(to: try await auth.hasAdmin() ? "/login" : "/onboarding")
            }
            return HTMLResponse {
                NewAgentPage(user: user, draft: .new(named: ""))
            }.response(from: request, context: context)
        }

        agents.get(":id") { request, context in
            guard let user = await TurgaiWebSupport.authenticatedDashboardUser(from: request, auth: auth) else {
                return TurgaiWebSupport.redirect(to: try await auth.hasAdmin() ? "/login" : "/onboarding")
            }
            guard let id = context.parameters.get("id"),
                let profile = try await agentProfiles.profile(id: id)
            else {
                return TurgaiWebSupport.redirect(to: "/")
            }
            let runtime = await runtimeSnapshots(.account(user.id)).filter { $0.profileID == profile.id }
            let placement: AgentDetailPage.Placement =
                try await agentProfiles.isDefaultProfile(id: profile.id) ? .default : .additional
            let draft = AgentDraft(profile, requestLimit: try await requestLimit(of: profile))
            return HTMLResponse {
                AgentDetailPage(
                    user: user,
                    profile: profile,
                    draft: draft,
                    runtime: runtime,
                    placement: placement
                )
            }.response(from: request, context: context)
        }

        // The chosen provider's models, as the form has it, while it's filled in: answered under the
        // model field, its models in place of the field's suggestions.
        agents.post("models") { request, context in
            guard await TurgaiWebSupport.authenticatedAdminUser(from: request, auth: auth) != nil else {
                return Response(status: .unauthorized)
            }
            let form = try await TurgaiWebSupport.decodeForm(from: request, context: context)
            let id = form["id"]?.first?.trimmed() ?? ""
            let saved = id.isEmpty ? nil : try await agentProfiles.profile(id: id)
            let outcome = await ModelSearch.search(
                AgentDraft(form: form, over: .new(named: "")), saved: saved?.providerConfiguration,
                credentials: agentCredentials)
            return HTMLResponse { ModelSearchAnswer(outcome: outcome) }.response(from: request, context: context)
        }

        // The chosen model's window, as the form has it: in place of its provider's context window
        // field.
        agents.post("models/window") { request, context in
            guard await TurgaiWebSupport.authenticatedAdminUser(from: request, auth: auth) != nil else {
                return Response(status: .unauthorized)
            }
            let form = try await TurgaiWebSupport.decodeForm(from: request, context: context)
            let id = form["id"]?.first?.trimmed() ?? ""
            let saved = id.isEmpty ? nil : try await agentProfiles.profile(id: id)
            let draft = AgentDraft(form: form, over: .new(named: ""))
            let model = await ModelWindow.ask(
                draft, saved: saved?.providerConfiguration, credentials: agentCredentials)
            return HTMLResponse {
                ContextWindowField(
                    provider: draft.provider, tokens: draft.settings.contextWindow, model: model, replacing: true)
            }.response(from: request, context: context)
        }

        agents.post("update") { request, context in
            guard let user = await TurgaiWebSupport.authenticatedAdminUser(from: request, auth: auth) else {
                return TurgaiWebSupport.redirect(to: try await auth.hasAdmin() ? "/login" : "/onboarding")
            }
            let form = try await TurgaiWebSupport.decodeForm(from: request, context: context)
            let id = form["id"]?.first ?? ""
            guard let existingProfile = try await agentProfiles.profile(id: id) else {
                return TurgaiWebSupport.redirect(to: "/")
            }
            let draft = AgentDraft(
                form: form, over: AgentDraft(existingProfile, requestLimit: try await requestLimit(of: existingProfile))
            )
            var pendingCredential: AgentCredentialReference?
            do {
                var profile = existingProfile
                profile.name = draft.name
                profile.reasoningEffort = try OnboardingInput.reasoningEffort(from: draft)
                let checked = try await OnboardingInput.submission(
                    from: draft, saved: existingProfile.providerConfiguration
                ).checked(credentials: agentCredentials)
                try profile.use(checked.configuration, model: checked.model)
                if let key = checked.newKey {
                    pendingCredential = key.reference
                    try await agentCredentials.save(key.value, for: key.reference)
                }
                profile.persona = draft.persona
                profile.instructions = draft.instructions
                try await agentProfiles.update(profile)
                try await saveRequestLimit(of: draft, for: profile)
                pendingCredential = nil
                if let oldReference = existingProfile.providerConfiguration.credentialReference,
                    oldReference != checked.configuration.credentialReference
                {
                    try? await agentCredentials.remove(oldReference)
                }
                return TurgaiWebSupport.redirect(to: "/agents/\(profile.id)")
            } catch {
                if let pendingCredential { try? await agentCredentials.remove(pendingCredential) }
                let runtime = await runtimeSnapshots(.account(user.id)).filter {
                    $0.profileID == existingProfile.id
                }
                let placement: AgentDetailPage.Placement =
                    try await agentProfiles.isDefaultProfile(id: existingProfile.id) ? .default : .additional
                return HTMLResponse {
                    AgentDetailPage(
                        user: user,
                        profile: existingProfile,
                        draft: draft,
                        runtime: runtime,
                        placement: placement,
                        error: TurgaiWebSupport.profileErrorMessage(error)
                    )
                }.response(from: request, context: context)
            }
        }

        agents.post("default") { request, context in
            guard await TurgaiWebSupport.authenticatedAdminUser(from: request, auth: auth) != nil else {
                return TurgaiWebSupport.redirect(to: try await auth.hasAdmin() ? "/login" : "/onboarding")
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

        agents.post("create") { request, context in
            guard let user = await TurgaiWebSupport.authenticatedAdminUser(from: request, auth: auth) else {
                return TurgaiWebSupport.redirect(to: try await auth.hasAdmin() ? "/login" : "/onboarding")
            }
            let form = try await TurgaiWebSupport.decodeForm(from: request, context: context)
            let draft = AgentDraft(form: form, over: .new(named: ""))
            var pendingCredential: AgentCredentialReference?
            do {
                let reasoningEffort = try OnboardingInput.reasoningEffort(from: draft)
                let checked = try await OnboardingInput.submission(from: draft, saved: nil)
                    .checked(credentials: agentCredentials)
                if let key = checked.newKey {
                    pendingCredential = key.reference
                    try await agentCredentials.save(key.value, for: key.reference)
                }
                let profile = try await agentProfiles.create(
                    name: draft.name,
                    providerConfiguration: checked.configuration,
                    modelID: checked.model,
                    reasoningEffort: reasoningEffort,
                    persona: draft.persona,
                    instructions: draft.instructions
                )
                try await saveRequestLimit(of: draft, for: profile)
                pendingCredential = nil
                return TurgaiWebSupport.redirect(to: "/agents/\(profile.id)")
            } catch {
                if let pendingCredential { try? await agentCredentials.remove(pendingCredential) }
                return HTMLResponse {
                    NewAgentPage(
                        user: user,
                        draft: draft,
                        error: TurgaiWebSupport.profileErrorMessage(error)
                    )
                }.response(from: request, context: context)
            }
        }

        agents.post("delete") { request, context in
            guard let user = await TurgaiWebSupport.authenticatedAdminUser(from: request, auth: auth) else {
                return TurgaiWebSupport.redirect(to: try await auth.hasAdmin() ? "/login" : "/onboarding")
            }
            let form = try await TurgaiWebSupport.decodeForm(from: request, context: context)
            let id = form["id"]?.first ?? ""
            guard let profile = try await agentProfiles.profile(id: id) else {
                return TurgaiWebSupport.redirect(to: "/")
            }
            do {
                try await agentProfiles.delete(id: id)
                if let reference = profile.providerConfiguration.credentialReference {
                    try? await agentCredentials.remove(reference)
                }
                return TurgaiWebSupport.redirect(to: "/")
            } catch {
                let runtime = await runtimeSnapshots(.account(user.id)).filter { $0.profileID == profile.id }
                let placement: AgentDetailPage.Placement =
                    try await agentProfiles.isDefaultProfile(id: profile.id) ? .default : .additional
                let draft = AgentDraft(profile, requestLimit: try await requestLimit(of: profile))
                return HTMLResponse {
                    AgentDetailPage(
                        user: user,
                        profile: profile,
                        draft: draft,
                        runtime: runtime,
                        placement: placement,
                        error: TurgaiWebSupport.profileErrorMessage(error)
                    )
                }.response(from: request, context: context)
            }
        }
    }
}
