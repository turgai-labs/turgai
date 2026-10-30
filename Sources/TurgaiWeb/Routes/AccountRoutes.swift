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

extension TurgaiMainWebApp {
    func registerAccountRoutes(on router: Router<BasicWebSocketRequestContext>, dependencies: TurgaiRouteDependencies) {
        registerSignIn(on: router.group("login"), dependencies: dependencies)
        registerRegistration(on: router.group("register"), dependencies: dependencies)
        registerSignOut(on: router.group("logout"), dependencies: dependencies)
        registerAccounts(on: router.group("accounts"), dependencies: dependencies)
    }

    /// Signing in.
    private func registerSignIn(
        on login: RouterGroup<BasicWebSocketRequestContext>, dependencies: TurgaiRouteDependencies
    ) {
        let auth = dependencies.auth
        let setup = dependencies.setup
        let agentProfiles = dependencies.agentProfiles
        login.get { request, context in
            guard try await auth.hasAdmin() else {
                return TurgaiWebSupport.redirect(to: "/onboarding")
            }
            if await TurgaiWebSupport.authenticatedUser(from: request, auth: auth) != nil {
                if let account = await TurgaiWebSupport.authenticatedAccount(from: request, auth: auth),
                    account.role == .user
                {
                    return TurgaiWebSupport.redirect(to: "/chat")
                }
                let isComplete = await setup.isComplete
                let isReady = await setup.isReady
                let hasDefaultProfile = try await agentProfiles.defaultProfile() != nil
                return TurgaiWebSupport.redirect(
                    to: isComplete && isReady && hasDefaultProfile ? "/" : "/onboarding/model"
                )
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
                let account = try await auth.accounts().first { $0.username == credentials.username }
                if account?.role == .user {
                    return TurgaiWebSupport.redirect(
                        to: "/chat", settingCookie: TurgaiWebSupport.sessionCookie(session.token)
                    )
                }
                let isComplete = await setup.isComplete
                let isReady = await setup.isReady
                let hasDefaultProfile = try await agentProfiles.defaultProfile() != nil
                let destination = isComplete && isReady && hasDefaultProfile ? "/" : "/onboarding/model"
                return TurgaiWebSupport.redirect(
                    to: destination, settingCookie: TurgaiWebSupport.sessionCookie(session.token))
            } catch {
                return HTMLResponse { LoginPage(error: "Invalid username or password.") }
                    .response(from: request, context: context)
            }
        }
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
            let credentials = CredentialsFormValues(form: form)
            do {
                _ = try await auth.register(username: credentials.username, password: credentials.password)
                let session = try await auth.signIn(
                    username: credentials.username,
                    password: credentials.password
                )
                return TurgaiWebSupport.redirect(
                    to: "/chat",
                    settingCookie: TurgaiWebSupport.sessionCookie(session.token)
                )
            } catch {
                return HTMLResponse {
                    RegisterAccountPage(error: TurgaiWebSupport.registrationErrorMessage(error))
                }.response(from: request, context: context)
            }
        }
    }

    /// Signing out.
    private func registerSignOut(
        on logout: RouterGroup<BasicWebSocketRequestContext>, dependencies: TurgaiRouteDependencies
    ) {
        logout.get { _, _ in
            TurgaiWebSupport.redirect(to: "/login", settingCookie: TurgaiWebSupport.expiredSessionCookie())
        }

        logout.post { _, _ in
            TurgaiWebSupport.redirect(to: "/login", settingCookie: TurgaiWebSupport.expiredSessionCookie())
        }
    }

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
