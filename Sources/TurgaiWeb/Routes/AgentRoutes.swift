import Elementary
import Hummingbird
import HummingbirdElementary
import HummingbirdWebSocket
import TurgaiApplication

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

    /// Chatting with a bot: the default one, or one chosen.
    private func registerChat(
        on chat: RouterGroup<BasicWebSocketRequestContext>, dependencies: TurgaiRouteDependencies
    ) {
        let auth = dependencies.auth
        let agentProfiles = dependencies.agentProfiles
        chat.get { request, context in
            guard let profile = try await agentProfiles.defaultProfile() else {
                return TurgaiWebSupport.redirect(to: "/onboarding")
            }
            guard let account = await TurgaiWebSupport.authenticatedAccount(from: request, auth: auth) else {
                return TurgaiWebSupport.redirect(to: try await auth.hasAdmin() ? "/login" : "/onboarding")
            }
            let response = HTMLResponse {
                ChatPage(
                    user: TurgaiWebSupport.userInfo(from: account),
                    profile: profile,
                    presentation: .publicChat
                )
            }.response(from: request, context: context)
            return response
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
            return HTMLResponse {
                ChatPage(user: user, profile: profile)
            }.response(from: request, context: context)
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
            let profiles = try await agentProfiles.profiles()
            let modelCatalog = await TurgaiWebSupport.modelCatalog(for: profiles)
            return HTMLResponse {
                NewAgentPage(user: user, modelCatalog: modelCatalog, draft: .new(named: "", in: modelCatalog))
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
            let profiles = try await agentProfiles.profiles()
            let modelCatalog = await TurgaiWebSupport.modelCatalog(for: profiles)
            let runtime = await runtimeSnapshots(.account(user.id)).filter { $0.profileID == profile.id }
            let placement: AgentDetailPage.Placement =
                try await agentProfiles.isDefaultProfile(id: profile.id) ? .default : .additional
            let draft = AgentDraft(profile, requestLimit: try await requestLimit(of: profile))
            return HTMLResponse {
                AgentDetailPage(
                    user: user,
                    profile: profile,
                    draft: draft,
                    modelCatalog: modelCatalog,
                    runtime: runtime,
                    placement: placement
                )
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
                form: form, over: AgentDraft(existingProfile, requestLimit: try await requestLimit(of: existingProfile)))
            var pendingCredential: AgentCredentialReference?
            do {
                var profile = existingProfile
                profile.name = draft.name
                let model = try OnboardingInput.model(from: draft)
                let reasoningEffort = try OnboardingInput.reasoningEffort(from: draft)
                profile.model = model
                profile.reasoningEffort = reasoningEffort
                let submission = try OnboardingInput.providerSubmission(
                    from: draft,
                    for: model,
                    existing: existingProfile.providerConfiguration
                )
                if let credential = submission.credential {
                    pendingCredential = credential.reference
                    try await agentCredentials.save(credential.value, for: credential.reference)
                }
                profile.providerConfiguration = submission.configuration
                profile.persona = draft.persona
                profile.instructions = draft.instructions
                try await agentProfiles.update(profile)
                try await saveRequestLimit(of: draft, for: profile)
                pendingCredential = nil
                if let oldReference = existingProfile.providerConfiguration.credentialReference,
                    oldReference != submission.configuration.credentialReference
                {
                    try? await agentCredentials.remove(oldReference)
                }
                return TurgaiWebSupport.redirect(to: "/agents/\(profile.id)")
            } catch {
                if let pendingCredential { try? await agentCredentials.remove(pendingCredential) }
                let profiles = try await agentProfiles.profiles()
                let modelCatalog = await TurgaiWebSupport.modelCatalog(for: profiles)
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
                        modelCatalog: modelCatalog,
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
            let modelCatalog = await TurgaiWebSupport.modelCatalog(for: try await agentProfiles.profiles())
            let draft = AgentDraft(form: form, over: .new(named: "", in: modelCatalog))
            var pendingCredential: AgentCredentialReference?
            do {
                let model = try OnboardingInput.model(from: draft)
                let reasoningEffort = try OnboardingInput.reasoningEffort(from: draft)
                let submission = try OnboardingInput.providerSubmission(from: draft, for: model)
                if let credential = submission.credential {
                    pendingCredential = credential.reference
                    try await agentCredentials.save(credential.value, for: credential.reference)
                }
                let profile = try await agentProfiles.create(
                    name: draft.name,
                    model: model,
                    reasoningEffort: reasoningEffort,
                    providerConfiguration: submission.configuration,
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
                        modelCatalog: modelCatalog,
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
                let profiles = try await agentProfiles.profiles()
                let modelCatalog = await TurgaiWebSupport.modelCatalog(for: profiles)
                let runtime = await runtimeSnapshots(.account(user.id)).filter { $0.profileID == profile.id }
                let placement: AgentDetailPage.Placement =
                    try await agentProfiles.isDefaultProfile(id: profile.id) ? .default : .additional
                let draft = AgentDraft(profile, requestLimit: try await requestLimit(of: profile))
                return HTMLResponse {
                    AgentDetailPage(
                        user: user,
                        profile: profile,
                        draft: draft,
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
