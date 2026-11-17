import Elementary
import Hail
import Hummingbird
import HummingbirdElementary
import HummingbirdWebSocket
import NIOCore
import TurgaiApplication
import TurgaiHail
import TurgaiPersistence
import TurgaiSpaces
import TurgaiTelegram

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

extension TurgaiMainWebApp {
    func registerAccountRoutes(on router: Router<BasicWebSocketRequestContext>, dependencies: TurgaiRouteDependencies) {
        registerSigningInAndOut(
            on: router, auth: dependencies.auth, setup: dependencies.setup)
        registerRegistration(on: router.group("register"), dependencies: dependencies)
        registerAccounts(on: router.group("accounts"), dependencies: dependencies)
    }
    /// Creating a chat account.
    private func registerRegistration(
        on registration: RouterGroup<BasicWebSocketRequestContext>, dependencies: TurgaiRouteDependencies
    ) {
        let auth = dependencies.auth
        registration.get { request, context in
            guard try await auth.hasAdmin() else {
                return TurgaiWebSupport.redirect(to: "/onboarding")
            }
            return HTMLResponse { RegisterAccountPage() }.response(from: request, context: context)
        }

        registration.post { request, context in
            guard try await auth.hasAdmin() else {
                return TurgaiWebSupport.redirect(to: "/onboarding")
            }
            let form = try await TurgaiWebSupport.decodeForm(from: request, context: context)
            let credentials = NewCredentialsFormValues(form: form)
            guard credentials.passwordsMatch else {
                return HTMLResponse {
                    RegisterAccountPage(error: NewCredentialsFormValues.passwordsDiffer)
                }.response(from: request, context: context)
            }
            let session: TurgaiSession
            do {
                _ = try await auth.register(username: credentials.username, password: credentials.password)
                session = try await auth.signIn(
                    username: credentials.username,
                    password: credentials.password
                )
            } catch {
                return HTMLResponse {
                    RegisterAccountPage(error: TurgaiWebSupport.registrationErrorMessage(error))
                }.response(from: request, context: context)
            }
            // In no space yet: one they're invited to, or one they make.
            return TurgaiWebSupport.redirect(
                to: "/",
                settingCookie: TurgaiWebSupport.sessionCookie(session.token)
            )
        }
    }

    /// Signing out.
    /// The accounts page, where administrators decide who can do what.
    private func registerAccounts(
        on accounts: RouterGroup<BasicWebSocketRequestContext>, dependencies: TurgaiRouteDependencies
    ) {
        let auth = dependencies.auth
        accounts.get { request, context in
            guard let user = await TurgaiWebSupport.authenticatedAdminUser(from: request, auth: auth) else {
                return TurgaiWebSupport.redirect(to: try await auth.hasAdmin() ? "/login" : "/onboarding")
            }
            let accounts = try await auth.accounts().map(TurgaiWebSupport.accountSummary)
            return HTMLResponse {
                AccountsPage(
                    user: user,
                    accounts: accounts
                )
            }.response(from: request, context: context)
        }

        accounts.post("action") { request, context in
            guard let user = await TurgaiWebSupport.authenticatedAdminUser(from: request, auth: auth) else {
                return TurgaiWebSupport.redirect(to: try await auth.hasAdmin() ? "/login" : "/onboarding")
            }
            let form = try await TurgaiWebSupport.decodeForm(from: request, context: context)
            guard let accountIDValue = form["id"]?.first,
                let accountID = UUID(uuidString: accountIDValue)
            else {
                return TurgaiWebSupport.redirect(to: "/accounts")
            }
            let action = AccountAction(rawValue: form["action"]?.first ?? "")
            do {
                switch action {
                case .approve:
                    try await auth.approve(id: accountID)
                case .enable:
                    try await auth.enable(id: accountID)
                case .disable:
                    try await auth.disable(id: accountID)
                case .administrator:
                    try await auth.setRole(accountID, role: .administrator)
                case .member:
                    try await auth.setRole(accountID, role: .member)
                case .user:
                    try await auth.setRole(accountID, role: .user)
                default:
                    throw TurgaiAuthError.invalidUsername
                }
                return TurgaiWebSupport.redirect(to: "/accounts")
            } catch {
                let accounts = try await auth.accounts().map(TurgaiWebSupport.accountSummary)
                return HTMLResponse {
                    AccountsPage(
                        user: user,
                        accounts: accounts,
                        error: TurgaiWebSupport.accountErrorMessage(error)
                    )
                }.response(from: request, context: context)
            }
        }
    }
}

/// Signing in and out, as setting up and Turgai both offer it.
func registerSigningInAndOut(
    on router: Router<BasicWebSocketRequestContext>, auth: TurgaiAuth, setup: TurgaiSetupStore
) {
    let login = router.group("login")
    login.get { request, context in
        guard try await auth.hasAdmin() else {
            return TurgaiWebSupport.redirect(to: "/onboarding")
        }
        // Signed in already: to their spaces, or on with setting up.
        if await TurgaiWebSupport.authenticatedUser(from: request, auth: auth) != nil {
            return TurgaiWebSupport.redirect(to: await setup.isComplete ? "/" : "/onboarding")
        }
        return HTMLResponse { LoginPage() }.response(from: request, context: context)
    }

    login.post { request, context in
        let form = try await TurgaiWebSupport.decodeForm(from: request, context: context)
        let credentials = CredentialsFormValues(form: form)
        do {
            let session = try await auth.signIn(
                username: credentials.username,
                password: credentials.password
            )
            // To their spaces, or on with setting up.
            return TurgaiWebSupport.redirect(
                to: await setup.isComplete ? "/" : "/onboarding",
                settingCookie: TurgaiWebSupport.sessionCookie(session.token))
        } catch {
            return HTMLResponse { LoginPage(error: "Invalid username or password.") }
                .response(from: request, context: context)
        }
    }
    let logout = router.group("logout")
    logout.get { _, _ in
        TurgaiWebSupport.redirect(to: "/login", settingCookie: TurgaiWebSupport.expiredSessionCookie())
    }
    logout.post { _, _ in
        TurgaiWebSupport.redirect(to: "/login", settingCookie: TurgaiWebSupport.expiredSessionCookie())
    }
}
