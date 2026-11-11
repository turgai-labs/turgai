import Elementary
import Hail
import Hummingbird
import HummingbirdElementary
import HummingbirdWebSocket
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

extension TurgaiOnboardingWebApp {
    func registerOnboardingRoutes(
        on router: Router<BasicWebSocketRequestContext>, dependencies: TurgaiRouteDependencies
    ) {
        let onboarding = router.group("onboarding")
        registerWelcome(on: onboarding, dependencies: dependencies)
        registerAdminStep(on: onboarding.group("register"), dependencies: dependencies)
        registerModelStep(on: onboarding.group("model"), dependencies: dependencies)
        registerStorageStep(on: onboarding.group("storage"), dependencies: dependencies)
        registerFinishStep(on: onboarding.group("finish"), dependencies: dependencies)
    }

    /// Setting up: the administrator account.
    private func registerAdminStep(
        on step: RouterGroup<BasicWebSocketRequestContext>, dependencies: TurgaiRouteDependencies
    ) {
        let auth = dependencies.auth
        step.get { request, context in
            guard !(try await auth.hasAdmin()) else {
                return TurgaiWebSupport.redirect(to: "/login")
            }
            let challenge = await auth.issueBootstrapChallenge()
            var response = HTMLResponse {
                RegisterPage(challenge: challenge)
            }.response(from: request, context: context)
            response.setCookie(TurgaiWebSupport.bootstrapChallengeCookie(challenge))
            return response
        }

        step.post { request, context in
            guard !(try await auth.hasAdmin()) else {
                return TurgaiWebSupport.redirect(to: "/login")
            }
            let form = try await TurgaiWebSupport.decodeForm(from: request, context: context)
            let challenge = form["challenge"]?.first ?? ""
            let confirmation = request.cookies[TurgaiWebSupport.bootstrapChallengeCookieName]?.value ?? ""
            let credentials = CredentialsFormValues(form: form)
            do {
                _ = try await auth.bootstrap(
                    username: credentials.username,
                    password: credentials.password,
                    challenge: challenge,
                    confirmation: confirmation
                )
                let session = try await auth.signIn(
                    username: credentials.username,
                    password: credentials.password
                )
                var response = TurgaiWebSupport.redirect(
                    to: "/onboarding/model",
                    settingCookie: TurgaiWebSupport.sessionCookie(session.token)
                )
                response.setCookie(TurgaiWebSupport.expiredBootstrapChallengeCookie())
                return response
            } catch {
                let challenge = await auth.issueBootstrapChallenge()
                var response = HTMLResponse {
                    RegisterPage(
                        challenge: challenge,
                        error: "Could not create the administrator: \(error)"
                    )
                }.response(from: request, context: context)
                response.setCookie(TurgaiWebSupport.bootstrapChallengeCookie(challenge))
                return response
            }
        }
    }

    /// Setting up: the first bot and its model.
    private func registerModelStep(
        on step: RouterGroup<BasicWebSocketRequestContext>, dependencies: TurgaiRouteDependencies
    ) {
        let auth = dependencies.auth
        let agentProfiles = dependencies.agentProfiles
        let agentCredentials = dependencies.agentCredentials
        step.get { request, context in
            guard await TurgaiWebSupport.authenticatedAdminUser(from: request, auth: auth) != nil else {
                return TurgaiWebSupport.redirect(to: try await auth.hasAdmin() ? "/login" : "/onboarding")
            }
            let profile = try await agentProfiles.defaultProfile()
            let draft = profile.map { AgentDraft($0, requestLimit: nil) }
            return HTMLResponse {
                ModelPage(draft: draft ?? .new(named: "Turgai"), profileID: profile?.id)
            }.response(from: request, context: context)
        }

        step.post { request, context in
            guard await TurgaiWebSupport.authenticatedAdminUser(from: request, auth: auth) != nil else {
                return TurgaiWebSupport.redirect(to: try await auth.hasAdmin() ? "/login" : "/onboarding")
            }
            let form = try await TurgaiWebSupport.decodeForm(from: request, context: context)
            let existingProfile = try await agentProfiles.defaultProfile()
            let draft = AgentDraft(
                form: form,
                over: existingProfile.map { AgentDraft($0, requestLimit: nil) } ?? .new(named: "Turgai"))
            var pendingCredential: AgentCredentialReference?
            do {
                let reasoningEffort = try OnboardingInput.reasoningEffort(from: draft)
                let checked = try await OnboardingInput.submission(
                    from: draft, saved: existingProfile?.providerConfiguration
                ).checked(credentials: agentCredentials)
                if let key = checked.newKey {
                    pendingCredential = key.reference
                    try await agentCredentials.save(key.value, for: key.reference)
                }
                if var profile = try await agentProfiles.defaultProfile() {
                    let oldReference = profile.providerConfiguration.credentialReference
                    try profile.use(checked.configuration, model: checked.model)
                    profile.reasoningEffort = reasoningEffort
                    profile.name = draft.name
                    profile.persona = draft.persona
                    profile.instructions = draft.instructions
                    try await agentProfiles.update(profile)
                    pendingCredential = nil
                    if let oldReference,
                        oldReference != checked.configuration.credentialReference
                    {
                        try? await agentCredentials.remove(oldReference)
                    }
                } else {
                    _ = try await agentProfiles.create(
                        name: draft.name,
                        providerConfiguration: checked.configuration,
                        modelID: checked.model,
                        reasoningEffort: reasoningEffort,
                        persona: draft.persona,
                        instructions: draft.instructions
                    )
                    pendingCredential = nil
                }
                return Response(status: .seeOther, headers: [.location: "/onboarding/storage"])
            } catch {
                if let pendingCredential { try? await agentCredentials.remove(pendingCredential) }
                return HTMLResponse {
                    ModelPage(
                        draft: draft,
                        profileID: existingProfile?.id,
                        error: TurgaiWebSupport.profileErrorMessage(error)
                    )
                }.response(from: request, context: context)
            }
        }
    }

    /// Setting up: where memory is kept.
    private func registerStorageStep(
        on step: RouterGroup<BasicWebSocketRequestContext>, dependencies: TurgaiRouteDependencies
    ) {
        let auth = dependencies.auth
        let setup = dependencies.setup
        let directory = dependencies.directory
        step.get { request, context in
            guard await TurgaiWebSupport.authenticatedAdminUser(from: request, auth: auth) != nil else {
                return TurgaiWebSupport.redirect(to: try await auth.hasAdmin() ? "/login" : "/onboarding")
            }
            let storage = await setup.storageConfiguration
            return HTMLResponse {
                StoragePage(
                    storage: storage,
                    directory: directory
                )
            }.response(from: request, context: context)
        }

        step.post { request, context in
            guard await TurgaiWebSupport.authenticatedAdminUser(from: request, auth: auth) != nil else {
                return TurgaiWebSupport.redirect(to: try await auth.hasAdmin() ? "/login" : "/onboarding")
            }
            let form = try await TurgaiWebSupport.decodeForm(from: request, context: context)
            let values = StorageFormValues(form: form)
            do {
                let storage = try OnboardingInput.storageConfiguration(from: form)
                try await setup.setStorage(storage)
                return Response(status: .seeOther, headers: [.location: "/onboarding/finish"])
            } catch {
                return HTMLResponse {
                    StoragePage(
                        values: values,
                        directory: directory,
                        error: TurgaiWebSupport.storageErrorMessage(error)
                    )
                }.response(from: request, context: context)
            }
        }
    }

    /// Setting up: the last step.
    private func registerFinishStep(
        on step: RouterGroup<BasicWebSocketRequestContext>, dependencies: TurgaiRouteDependencies
    ) {
        let auth = dependencies.auth
        let setup = dependencies.setup
        let agentProfiles = dependencies.agentProfiles
        step.get { request, context in
            guard await TurgaiWebSupport.authenticatedAdminUser(from: request, auth: auth) != nil else {
                return TurgaiWebSupport.redirect(to: try await auth.hasAdmin() ? "/login" : "/onboarding")
            }
            guard await setup.isReady, try await agentProfiles.defaultProfile() != nil else {
                return TurgaiWebSupport.redirect(to: "/onboarding/model")
            }
            guard !(await setup.isComplete) else {
                return TurgaiWebSupport.redirect(to: "/")
            }
            return HTMLResponse { FinishPage() }
                .response(from: request, context: context)
        }

        step.post { request, context in
            guard await TurgaiWebSupport.authenticatedAdminUser(from: request, auth: auth) != nil else {
                return TurgaiWebSupport.redirect(to: try await auth.hasAdmin() ? "/login" : "/onboarding")
            }
            guard await setup.isReady, try await agentProfiles.defaultProfile() != nil else {
                return TurgaiWebSupport.redirect(to: "/onboarding/model")
            }
            try await setup.complete()
            return TurgaiWebSupport.redirect(to: "/")
        }
    }

    /// Setting up: where it starts.
    private func registerWelcome(
        on welcome: RouterGroup<BasicWebSocketRequestContext>, dependencies: TurgaiRouteDependencies
    ) {
        let auth = dependencies.auth
        welcome.get { request, context in
            if try await auth.hasAdmin() {
                guard await TurgaiWebSupport.authenticatedAdminUser(from: request, auth: auth) != nil else {
                    return TurgaiWebSupport.redirect(to: "/login")
                }
                return TurgaiWebSupport.redirect(to: "/onboarding/model")
            }
            return HTMLResponse { OnboardingPage() }.response(from: request, context: context)
        }
    }
}
