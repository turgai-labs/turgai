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

extension TurgaiOnboardingWebApp {
    func registerOnboardingRoutes(on router: Router<BasicRequestContext>, dependencies: TurgaiRouteDependencies) {
        let auth = dependencies.auth
        let setup = dependencies.setup
        let agentProfiles = dependencies.agentProfiles
        let defaultFileDirectory = dependencies.defaultFileDirectory
        router.get("/onboarding") { request, context in
            if await auth.hasAdmin() {
                guard await TurgaiWebSupport.authenticatedAdminUser(from: request, auth: auth) != nil else {
                    return TurgaiWebSupport.redirect(to: "/login")
                }
                return TurgaiWebSupport.redirect(to: "/onboarding/model")
            }
            return HTMLResponse { OnboardingPage() }.response(from: request, context: context)
        }
        router.get("/onboarding/register") { request, context in
            guard !(await auth.hasAdmin()) else {
                return TurgaiWebSupport.redirect(to: "/login")
            }
            let challenge = await auth.issueBootstrapChallenge()
            var response = HTMLResponse {
                RegisterPage(challenge: challenge)
            }.response(from: request, context: context)
            response.setCookie(TurgaiWebSupport.bootstrapChallengeCookie(challenge))
            return response
        }
        router.post("/onboarding/register") { request, context in
            guard !(await auth.hasAdmin()) else {
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
        router.get("/onboarding/model") { request, context in
            guard await TurgaiWebSupport.authenticatedAdminUser(from: request, auth: auth) != nil else {
                return TurgaiWebSupport.redirect(to: await auth.hasAdmin() ? "/login" : "/onboarding")
            }
            let profiles = await agentProfiles.profiles()
            let modelCatalog = await TurgaiWebSupport.modelCatalog(for: profiles)
            let profile = await agentProfiles.defaultProfile()
            return HTMLResponse {
                ModelPage(modelCatalog: modelCatalog, profile: profile)
            }.response(from: request, context: context)
        }
        router.post("/onboarding/model") { request, context in
            guard await TurgaiWebSupport.authenticatedAdminUser(from: request, auth: auth) != nil else {
                return TurgaiWebSupport.redirect(to: await auth.hasAdmin() ? "/login" : "/onboarding")
            }
            let form = try await TurgaiWebSupport.decodeForm(from: request, context: context)
            do {
                let values = BotFormValues(form: form, nameKey: "agentName")
                let modelValues = ModelFormValues(form: form)
                let model = try OnboardingInput.model(from: modelValues)
                let ollamaBaseURL = try OnboardingInput.ollamaBaseURL(from: modelValues, for: model)
                let contextWindow = try OnboardingInput.positiveInteger(
                    values.contextWindow,
                    field: "context window"
                )
                if var profile = await agentProfiles.defaultProfile() {
                    profile.model = model
                    profile.ollamaBaseURL = ollamaBaseURL
                    profile.name = values.name
                    profile.persona = values.persona
                    profile.instructions = values.instructions
                    profile.contextWindow = contextWindow
                    try await agentProfiles.update(profile)
                } else {
                    _ = try await agentProfiles.create(
                        name: values.name,
                        model: model,
                        ollamaBaseURL: ollamaBaseURL,
                        contextWindow: contextWindow,
                        persona: values.persona,
                        instructions: values.instructions
                    )
                }
                return Response(status: .seeOther, headers: [.location: "/onboarding/storage"])
            } catch {
                let profiles = await agentProfiles.profiles()
                let modelCatalog = await TurgaiWebSupport.modelCatalog(for: profiles)
                let profile = await agentProfiles.defaultProfile()
                return HTMLResponse {
                    ModelPage(
                        modelCatalog: modelCatalog,
                        profile: profile,
                        error: TurgaiWebSupport.profileErrorMessage(error)
                    )
                }.response(from: request, context: context)
            }
        }
        router.get("/onboarding/storage") { request, context in
            guard await TurgaiWebSupport.authenticatedAdminUser(from: request, auth: auth) != nil else {
                return TurgaiWebSupport.redirect(to: await auth.hasAdmin() ? "/login" : "/onboarding")
            }
            let storage = await setup.storageConfiguration
            return HTMLResponse {
                StoragePage(
                    storage: storage,
                    defaultFileDirectory: defaultFileDirectory
                )
            }.response(from: request, context: context)
        }
        router.post("/onboarding/storage") { request, context in
            guard await TurgaiWebSupport.authenticatedAdminUser(from: request, auth: auth) != nil else {
                return TurgaiWebSupport.redirect(to: await auth.hasAdmin() ? "/login" : "/onboarding")
            }
            let form = try await TurgaiWebSupport.decodeForm(from: request, context: context)
            let values = StorageFormValues(form: form, defaultFileDirectory: defaultFileDirectory)
            do {
                let storage = try OnboardingInput.storageConfiguration(
                    from: form,
                    defaultFileDirectory: defaultFileDirectory
                )
                try await setup.setStorage(
                    storage,
                    postgresPassword: form["postgresPassword"]?.first
                )
                return Response(status: .seeOther, headers: [.location: "/onboarding/telegram"])
            } catch {
                return HTMLResponse {
                    StoragePage(
                        values: values,
                        defaultFileDirectory: defaultFileDirectory,
                        error: TurgaiWebSupport.storageErrorMessage(error)
                    )
                }.response(from: request, context: context)
            }
        }
        router.get("/onboarding/telegram") { request, context in
            guard await TurgaiWebSupport.authenticatedAdminUser(from: request, auth: auth) != nil else {
                return TurgaiWebSupport.redirect(to: await auth.hasAdmin() ? "/login" : "/onboarding")
            }
            let chatIDs = await setup.telegramChatIDs
            return HTMLResponse {
                TelegramPage(chatIDs: chatIDs)
            }.response(from: request, context: context)
        }
        router.post("/onboarding/telegram") { request, context in
            guard await TurgaiWebSupport.authenticatedAdminUser(from: request, auth: auth) != nil else {
                return TurgaiWebSupport.redirect(to: await auth.hasAdmin() ? "/login" : "/onboarding")
            }
            let form = try await TurgaiWebSupport.decodeForm(from: request, context: context)
            let values = TelegramFormValues(form: form)
            guard let token = values.token?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty
            else {
                return HTMLResponse { TelegramPage(error: "A Telegram bot token is required.") }
                    .response(from: request, context: context)
            }
            let chatIDs: [Int64]
            do {
                chatIDs = try OnboardingInput.chatIDs(from: values.chatIDs)
            } catch {
                return HTMLResponse {
                    TelegramPage(error: TurgaiWebSupport.telegramErrorMessage(error))
                }.response(from: request, context: context)
            }
            do {
                let telegramClient = try TelegramAPIClient.live(token: token)
                try await telegramClient.validateToken()
                try await setup.setTelegramToken(token, chatIDs: chatIDs)
            } catch {
                return HTMLResponse {
                    TelegramPage(chatIDs: chatIDs, error: TurgaiWebSupport.telegramErrorMessage(error))
                }.response(from: request, context: context)
            }
            return Response(status: .seeOther, headers: [.location: "/onboarding/finish"])
        }
        router.get("/onboarding/finish") { request, context in
            guard await TurgaiWebSupport.authenticatedAdminUser(from: request, auth: auth) != nil else {
                return TurgaiWebSupport.redirect(to: await auth.hasAdmin() ? "/login" : "/onboarding")
            }
            guard await setup.isReady, await agentProfiles.defaultProfile() != nil else {
                return TurgaiWebSupport.redirect(to: "/onboarding/model")
            }
            guard !(await setup.isComplete) else {
                return TurgaiWebSupport.redirect(to: "/")
            }
            return HTMLResponse { FinishPage() }
                .response(from: request, context: context)
        }
        router.post("/onboarding/finish") { request, context in
            guard await TurgaiWebSupport.authenticatedAdminUser(from: request, auth: auth) != nil else {
                return TurgaiWebSupport.redirect(to: await auth.hasAdmin() ? "/login" : "/onboarding")
            }
            guard await setup.isReady, await agentProfiles.defaultProfile() != nil else {
                return TurgaiWebSupport.redirect(to: "/onboarding/model")
            }
            try await setup.complete()
            return TurgaiWebSupport.redirect(to: "/")
        }
    }
}
