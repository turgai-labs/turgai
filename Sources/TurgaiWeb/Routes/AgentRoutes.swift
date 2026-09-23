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
        let auth = dependencies.auth
        let agentProfiles = dependencies.agentProfiles
        let runtimeSnapshots = dependencies.runtimeSnapshots
        router.get("/chat") { request, context in
            guard let profile = await agentProfiles.defaultProfile() else {
                return TurgaiWebSupport.redirect(to: "/onboarding")
            }
            guard let account = await TurgaiWebSupport.authenticatedAccount(from: request, auth: auth) else {
                return TurgaiWebSupport.redirect(to: await auth.hasAdmin() ? "/login" : "/onboarding")
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
        router.get("/chat/:id") { request, context in
            guard let user = await TurgaiWebSupport.authenticatedDashboardUser(from: request, auth: auth) else {
                return TurgaiWebSupport.redirect(to: await auth.hasAdmin() ? "/login" : "/onboarding")
            }
            guard let id = context.parameters.get("id"),
                let profile = await agentProfiles.profile(id: id)
            else {
                return TurgaiWebSupport.redirect(to: "/")
            }
            return HTMLResponse {
                ChatPage(user: user, profile: profile)
            }.response(from: request, context: context)
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
                let reasoningEffort = try OnboardingInput.reasoningEffort(from: modelValues)
                profile.model = model
                profile.reasoningEffort = reasoningEffort
                profile.providerConfiguration = try OnboardingInput.providerConfiguration(
                    from: modelValues,
                    for: model
                )
                profile.contextWindow = try OnboardingInput.positiveInteger(
                    values.contextWindow,
                    field: "context window"
                )
                profile.persona = values.persona
                profile.instructions = values.instructions
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
                let reasoningEffort = try OnboardingInput.reasoningEffort(from: modelValues)
                let providerConfiguration = try OnboardingInput.providerConfiguration(
                    from: modelValues,
                    for: model
                )
                let contextWindow = try OnboardingInput.positiveInteger(
                    values.contextWindow,
                    field: "context window"
                )
                let profile = try await agentProfiles.create(
                    name: values.name,
                    model: model,
                    reasoningEffort: reasoningEffort,
                    providerConfiguration: providerConfiguration,
                    contextWindow: contextWindow,
                    persona: values.persona,
                    instructions: values.instructions
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
