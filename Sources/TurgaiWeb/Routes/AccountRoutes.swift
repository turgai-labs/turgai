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
    func registerAccountRoutes(on router: Router<BasicRequestContext>, dependencies: TurgaiRouteDependencies) {
        let auth = dependencies.auth
        let setup = dependencies.setup
        let agentProfiles = dependencies.agentProfiles
        router.get("/login") { request, context in
            guard await auth.hasAdmin() else {
                return TurgaiWebSupport.redirect(to: "/onboarding")
            }
            if await TurgaiWebSupport.authenticatedUser(from: request, auth: auth) != nil {
                let isComplete = await setup.isComplete
                let isReady = await setup.isReady
                let hasDefaultProfile = await agentProfiles.defaultProfile() != nil
                return TurgaiWebSupport.redirect(
                    to: isComplete && isReady && hasDefaultProfile ? "/" : "/onboarding/model"
                )
            }
            return HTMLResponse { LoginPage() }.response(from: request, context: context)
        }
        router.get("/accounts") { request, context in
            guard let user = await TurgaiWebSupport.authenticatedAdminUser(from: request, auth: auth) else {
                return TurgaiWebSupport.redirect(to: await auth.hasAdmin() ? "/login" : "/onboarding")
            }
            let accounts = await auth.accounts().map(TurgaiWebSupport.accountSummary)
            return HTMLResponse {
                AccountsPage(
                    user: user,
                    accounts: accounts
                )
            }.response(from: request, context: context)
        }
        router.post("/accounts/action") { request, context in
            guard let user = await TurgaiWebSupport.authenticatedAdminUser(from: request, auth: auth) else {
                return TurgaiWebSupport.redirect(to: await auth.hasAdmin() ? "/login" : "/onboarding")
            }
            let form = try await TurgaiWebSupport.decodeForm(from: request, context: context)
            guard let accountIDValue = form["id"]?.first,
                let accountID = Foundation.UUID(uuidString: accountIDValue)
            else {
                return TurgaiWebSupport.redirect(to: "/accounts")
            }
            let action = AccountAction(rawValue: form["action"]?.first ?? "")
            do {
                switch action {
                case .approve:
                    try await auth.approve(id: accountID)
                case .disable:
                    try await auth.disable(id: accountID)
                case .administrator:
                    try await auth.setRole(accountID, role: .administrator)
                case .member:
                    try await auth.setRole(accountID, role: .member)
                default:
                    throw TurgaiAuthError.invalidUsername
                }
                return TurgaiWebSupport.redirect(to: "/accounts")
            } catch {
                let accounts = await auth.accounts().map(TurgaiWebSupport.accountSummary)
                return HTMLResponse {
                    AccountsPage(
                        user: user,
                        accounts: accounts,
                        error: TurgaiWebSupport.accountErrorMessage(error)
                    )
                }.response(from: request, context: context)
            }
        }
        router.get("/register") { request, context in
            guard await auth.hasAdmin() else {
                return TurgaiWebSupport.redirect(to: "/onboarding")
            }
            return HTMLResponse { RegisterAccountPage() }.response(from: request, context: context)
        }
        router.post("/register") { request, context in
            guard await auth.hasAdmin() else {
                return TurgaiWebSupport.redirect(to: "/onboarding")
            }
            let form = try await TurgaiWebSupport.decodeForm(from: request, context: context)
            let credentials = CredentialsFormValues(form: form)
            do {
                _ = try await auth.register(username: credentials.username, password: credentials.password)
                return HTMLResponse {
                    RegisterAccountPage(
                        success: "Your account is ready for administrator approval."
                    )
                }.response(from: request, context: context)
            } catch {
                return HTMLResponse {
                    RegisterAccountPage(error: TurgaiWebSupport.registrationErrorMessage(error))
                }.response(from: request, context: context)
            }
        }
        router.post("/login") { request, context in
            let form = try await TurgaiWebSupport.decodeForm(from: request, context: context)
            let credentials = CredentialsFormValues(form: form)
            do {
                let session = try await auth.signIn(
                    username: credentials.username,
                    password: credentials.password
                )
                let isComplete = await setup.isComplete
                let isReady = await setup.isReady
                let hasDefaultProfile = await agentProfiles.defaultProfile() != nil
                let destination = isComplete && isReady && hasDefaultProfile ? "/" : "/onboarding/model"
                return TurgaiWebSupport.redirect(
                    to: destination, settingCookie: TurgaiWebSupport.sessionCookie(session.token))
            } catch {
                return HTMLResponse { LoginPage(error: "Invalid username or password.") }
                    .response(from: request, context: context)
            }
        }
        router.get("/logout") { _, _ in
            TurgaiWebSupport.redirect(to: "/login", settingCookie: TurgaiWebSupport.expiredSessionCookie())
        }
        router.post("/logout") { _, _ in
            TurgaiWebSupport.redirect(to: "/login", settingCookie: TurgaiWebSupport.expiredSessionCookie())
        }
    }
}
