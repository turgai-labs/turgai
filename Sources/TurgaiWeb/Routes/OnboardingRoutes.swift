import Elementary
import Hail
import Hummingbird
import HummingbirdElementary
import HummingbirdWebSocket
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

extension TurgaiOnboardingWebApp {
    func registerOnboardingRoutes(on router: Router<BasicWebSocketRequestContext>) {
        let onboarding = router.group("onboarding")
        registerWelcome(on: onboarding)
        registerAdminStep(on: onboarding.group("register"))
        registerModelStep(on: onboarding.group("model"))
        registerModelAsking(on: onboarding.group("model"))
        registerStorageStep(on: onboarding.group("storage"))
        registerFinishStep(on: onboarding.group("finish"))
    }

    /// Setting up: the administrator account.
    private func registerAdminStep(
        on step: RouterGroup<BasicWebSocketRequestContext>
    ) {
        let auth = self.auth
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
            let credentials = NewCredentialsFormValues(form: form)
            guard credentials.passwordsMatch else {
                let challenge = await auth.issueBootstrapChallenge()
                var response = HTMLResponse {
                    RegisterPage(challenge: challenge, error: NewCredentialsFormValues.passwordsDiffer)
                }.response(from: request, context: context)
                response.setCookie(TurgaiWebSupport.bootstrapChallengeCookie(challenge))
                return response
            }
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
                    to: "/onboarding/storage",
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

    /// Setting up: the first space, its name and its first bot. Kept with setting up until the
    /// space is made, as Turgai starts, by whoever set it up, as anyone makes a space.
    private func registerModelStep(
        on step: RouterGroup<BasicWebSocketRequestContext>
    ) {
        let auth = self.auth
        let setup = self.setup
        let agentCredentials = self.agentCredentials
        step.get { request, context in
            guard await TurgaiWebSupport.authenticatedAdminUser(from: request, auth: auth) != nil else {
                return TurgaiWebSupport.redirect(to: try await auth.hasAdmin() ? "/login" : "/onboarding")
            }
            let first = await setup.firstSpace
            return HTMLResponse {
                ModelPage(
                    spaceName: first?.name.rawValue ?? "",
                    draft: first.map { AgentDraft($0.bot, requestLimit: nil) } ?? .new(named: "Turgai"),
                    profileID: first?.bot.id.description)
            }.response(from: request, context: context)
        }

        step.post { request, context in
            guard let user = await TurgaiWebSupport.authenticatedAdminUser(from: request, auth: auth) else {
                return TurgaiWebSupport.redirect(to: try await auth.hasAdmin() ? "/login" : "/onboarding")
            }
            let form = try await TurgaiWebSupport.decodeForm(from: request, context: context)
            let first = await setup.firstSpace
            let existing = first?.bot
            let draft = AgentDraft(
                form: form, over: existing.map { AgentDraft($0, requestLimit: nil) } ?? .new(named: "Turgai"))
            let written = form["spaceName"]?.first ?? ""
            guard let name = SpaceName(written) else {
                return HTMLResponse {
                    ModelPage(
                        spaceName: written, draft: draft, profileID: existing?.id.description,
                        error: "Give the space a name.")
                }.response(from: request, context: context)
            }
            var pendingCredential: AgentCredentialReference?
            do {
                let (bot, newKey) = try await draft.bot(over: existing, credentials: agentCredentials)
                if let newKey {
                    pendingCredential = newKey.reference
                    try await agentCredentials.save(newKey.value, for: newKey.reference)
                }
                try await setup.setFirstSpace(
                    FirstSpace(id: first?.id ?? SpaceID(), name: name, maker: .account(user.id), bot: bot))
                pendingCredential = nil
                if let old = existing?.model.location.credentialReference,
                    old != bot.model.location.credentialReference
                {
                    try? await agentCredentials.remove(old)
                }
                return Response(status: .seeOther, headers: [.location: "/onboarding/finish"])
            } catch {
                if let pendingCredential { try? await agentCredentials.remove(pendingCredential) }
                return HTMLResponse {
                    ModelPage(
                        spaceName: written, draft: draft, profileID: existing?.id.description,
                        error: TurgaiWebSupport.profileErrorMessage(error))
                }.response(from: request, context: context)
            }
        }
    }

    /// Setting up: the chosen provider's models, and the chosen model's window, as the model step's
    /// form has them while it's filled in, answered under the model field; asked with the key
    /// typed, or else the one the first bot keeps.
    private func registerModelAsking(
        on step: RouterGroup<BasicWebSocketRequestContext>
    ) {
        let auth = self.auth
        let setup = self.setup
        let agentCredentials = self.agentCredentials
        /// Where the first bot's model runs, when the form is the first bot's.
        @Sendable func saved(_ form: [String: [String]]) async -> AgentProviderConfiguration? {
            guard let first = await setup.firstSpace?.bot, form["id"]?.first == first.id.description else {
                return nil
            }
            return first.model.location
        }
        step.post("models") { request, context in
            guard await TurgaiWebSupport.authenticatedAdminUser(from: request, auth: auth) != nil else {
                return Response(status: .unauthorized)
            }
            let form = try await TurgaiWebSupport.decodeForm(from: request, context: context)
            let outcome = await ModelSearch.search(
                AgentDraft(form: form, over: .new(named: "")), saved: await saved(form),
                credentials: agentCredentials)
            return HTMLResponse { ModelSearchAnswer(outcome: outcome) }.response(from: request, context: context)
        }
        step.post("models/window") { request, context in
            guard await TurgaiWebSupport.authenticatedAdminUser(from: request, auth: auth) != nil else {
                return Response(status: .unauthorized)
            }
            let form = try await TurgaiWebSupport.decodeForm(from: request, context: context)
            let draft = AgentDraft(form: form, over: .new(named: ""))
            let model = await ModelWindow.ask(draft, saved: await saved(form), credentials: agentCredentials)
            return HTMLResponse {
                ContextWindowField(
                    provider: draft.provider, tokens: draft.settings.contextWindow, model: model, replacing: true)
            }.response(from: request, context: context)
        }
    }

    /// Setting up: where memory is kept.
    private func registerStorageStep(
        on step: RouterGroup<BasicWebSocketRequestContext>
    ) {
        let auth = self.auth
        let setup = self.setup
        let directory = self.directory
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
                return Response(status: .seeOther, headers: [.location: "/onboarding/model"])
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
        on step: RouterGroup<BasicWebSocketRequestContext>
    ) {
        let auth = self.auth
        let setup = self.setup
        step.get { request, context in
            guard await TurgaiWebSupport.authenticatedAdminUser(from: request, auth: auth) != nil else {
                return TurgaiWebSupport.redirect(to: try await auth.hasAdmin() ? "/login" : "/onboarding")
            }
            guard await setup.isReady else {
                return TurgaiWebSupport.redirect(
                    to: await setup.storageConfiguration == nil ? "/onboarding/storage" : "/onboarding/model")
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
            guard await setup.isReady else {
                return TurgaiWebSupport.redirect(
                    to: await setup.storageConfiguration == nil ? "/onboarding/storage" : "/onboarding/model")
            }
            try await setup.complete()
            // Setting up ends here, and Turgai starts: the page waits until it answers.
            return HTMLResponse { StartingPage() }.response(from: request, context: context)
        }
    }

    /// Setting up: where it starts.
    private func registerWelcome(
        on welcome: RouterGroup<BasicWebSocketRequestContext>
    ) {
        let auth = self.auth
        welcome.get { request, context in
            if try await auth.hasAdmin() {
                guard await TurgaiWebSupport.authenticatedAdminUser(from: request, auth: auth) != nil else {
                    return TurgaiWebSupport.redirect(to: "/login")
                }
                return TurgaiWebSupport.redirect(to: "/onboarding/storage")
            }
            return HTMLResponse { OnboardingPage() }.response(from: request, context: context)
        }
    }
}
