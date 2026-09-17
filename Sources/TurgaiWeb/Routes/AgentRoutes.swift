import Elementary
import Hail
import Hummingbird
import HummingbirdElementary
import NIOCore
import TurgaiApplication
import TurgaiHail
import TurgaiPersistence
import TurgaiTelegram

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

extension TurgaiMainWebApp {
    func registerAgentRoutes(on router: Router<BasicRequestContext>, dependencies: TurgaiRouteDependencies) {
        let auth = dependencies.auth
        let agentProfiles = dependencies.agentProfiles
        let runtimeSnapshots = dependencies.runtimeSnapshots
        router.get("/agents/new") { request, context in
            guard let user = await TurgaiWebSupport.authenticatedUser(from: request, auth: auth) else {
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
            guard let user = await TurgaiWebSupport.authenticatedUser(from: request, auth: auth) else {
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
            let isDefaultProfile = await agentProfiles.isDefaultProfile(id: profile.id)
            return HTMLResponse {
                AgentDetailPage(
                    user: user,
                    profile: profile,
                    modelCatalog: modelCatalog,
                    runtime: runtime,
                    isDefaultProfile: isDefaultProfile
                )
            }.response(from: request, context: context)
        }
        router.post("/agents/update") { request, context in
            guard let user = await TurgaiWebSupport.authenticatedUser(from: request, auth: auth) else {
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
                let isDefaultProfile = await agentProfiles.isDefaultProfile(id: existingProfile.id)
                return HTMLResponse {
                    AgentDetailPage(
                        user: user,
                        profile: existingProfile,
                        modelCatalog: modelCatalog,
                        runtime: runtime,
                        isDefaultProfile: isDefaultProfile,
                        error: TurgaiWebSupport.profileErrorMessage(error)
                    )
                }.response(from: request, context: context)
            }
        }
        router.post("/agents/create") { request, context in
            guard let user = await TurgaiWebSupport.authenticatedUser(from: request, auth: auth) else {
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
            guard let user = await TurgaiWebSupport.authenticatedUser(from: request, auth: auth) else {
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
                let isDefaultProfile = await agentProfiles.isDefaultProfile(id: profile.id)
                return HTMLResponse {
                    AgentDetailPage(
                        user: user,
                        profile: profile,
                        modelCatalog: modelCatalog,
                        runtime: runtime,
                        isDefaultProfile: isDefaultProfile,
                        error: TurgaiWebSupport.profileErrorMessage(error)
                    )
                }.response(from: request, context: context)
            }
        }
    }
}
