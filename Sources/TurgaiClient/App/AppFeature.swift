import ComposableArchitecture
import Foundation
import SwiftUI
import TurgaiModels

#if os(macOS)
    import AppKit
#else
    import UIKit
#endif

/// Waits for the local server to be running and set up, signs in, then runs the chat.
@Reducer
package struct AppFeature {
    package init() {}

    package enum Connection: Equatable, Sendable {
        case checking
        /// Nothing answers yet: the server is still starting, or it stopped.
        case unreachable
        /// The server runs, but onboarding hasn't finished.
        case setupPending
        case ready
    }

    /// The server the app talks to: one it runs itself, or one it's told the address of.
    package enum Server: Equatable, Sendable {
        case own(ServerAddress)
        case elsewhere(ServerAddress)

        package var address: ServerAddress {
            switch self {
            case .own(let address), .elsewhere(let address): address
            }
        }
    }

    /// Waiting for the server: whose it is, and how it answers so far.
    package struct Waiting: Equatable, Sendable {
        package let connection: Connection
        package let server: Server

        /// What the waiting card says first.
        package var title: String {
            switch (connection, server) {
            case (.checking, _): "Looking for Turgai"
            case (.unreachable, .own): "Turgai is starting"
            case (.unreachable, .elsewhere): "Turgai doesn't answer"
            case (.setupPending, _), (.ready, _): "Almost there"
            }
        }

        /// What the waiting card says next.
        package var message: String {
            switch (connection, server) {
            case (.checking, .own): "One moment."
            case (.checking, .elsewhere(let address)): "At \(address.shown)."
            case (.unreachable, .own):
                "I'll open the chat as soon as it answers. If it stopped, the menu bar says why."
            case (.unreachable, .elsewhere(let address)):
                "Nothing answers at \(address.shown) yet. I'll ask again when you're back here, or choose another server."
            case (.setupPending, .own), (.ready, .own):
                "Finish setting up in your browser: an account, a model, and storage. I'll open the chat when you're done."
            case (.setupPending, .elsewhere(let address)), (.ready, .elsewhere(let address)):
                "Finish setting up Turgai in a browser at \(address.shown): an account, a model, and storage. I'll open the chat when you're done."
            }
        }

        /// Whether another server can be chosen instead: one only it was told the address of.
        package var canChangeServer: Bool {
            if case .elsewhere = server { true } else { false }
        }
    }

    package enum Account: Equatable, Sendable {
        /// The keychain hasn't been read yet.
        case unknown
        case signedOut
        case signedIn(Session)
    }

    package struct LoginForm: Equatable, Sendable {
        package enum Mode: Equatable, Sendable {
            case signIn
            /// Create a chat account, then sign in to it.
            case register
        }

        package enum Progress: Equatable, Sendable {
            case editing
            case submitting
        }

        /// Why the form is shown, or what went wrong.
        package enum Notice: Equatable, Sendable {
            case sessionEnded
            case invalidCredentials
            case invalidUsername
            case weakPassword
            /// The new password typed twice, differently.
            case passwordsDiffer
            /// The server refused a registration that passed the rules below.
            case usernameUnavailable
            case unavailable(String)

            package var text: String {
                switch self {
                case .sessionEnded: "Your session ended. Sign in again."
                case .invalidCredentials: "That username and password didn't match."
                case .invalidUsername: "Choose a username of 3 to 64 letters, numbers, dots, dashes, or underscores."
                case .weakPassword: "Choose a password with at least 12 characters."
                case .passwordsDiffer: "The two passwords differ. Type the same password in both."
                case .usernameUnavailable: "Turgai couldn't create that account. The username may be taken."
                case .unavailable(let reason): "Turgai didn't answer (\(reason)). Try again in a moment."
                }
            }
        }

        package var mode = Mode.signIn
        package var username = ""
        package var password = ""
        /// A new password typed again, when creating an account.
        package var passwordAgain = ""
        package var progress = Progress.editing
        package var notice: Notice?

        /// What the form is called, and what its button says.
        package var title: String {
            switch mode {
            case .signIn: "Sign in"
            case .register: "Create account"
            }
        }

        /// The mode the form switches to.
        package var otherMode: Mode {
            switch mode {
            case .signIn: .register
            case .register: .signIn
            }
        }

        /// What the button that switches the mode says.
        package var switchPrompt: String {
            switch mode {
            case .signIn: "Create an account"
            case .register: "I have an account"
            }
        }

        package var isSubmitting: Bool { progress == .submitting }

        /// A username and a password are typed, and a new password typed again.
        package var isFilled: Bool {
            switch mode {
            case .signIn: !username.isEmpty && !password.isEmpty
            case .register: !username.isEmpty && !password.isEmpty && !passwordAgain.isEmpty
            }
        }

        /// What the server would refuse in a registration, checked first so the message is precise.
        /// Mirrors `TurgaiAuth`'s rules; keep them in step.
        package var registrationProblem: Notice? {
            let allowed = CharacterSet(
                charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-.")
            if !(3...64).contains(username.count)
                || !username.unicodeScalars.allSatisfy(allowed.contains)
            {
                return .invalidUsername
            }
            if password.count < 12 { return .weakPassword }
            if password != passwordAgain { return .passwordsDiffer }
            return nil
        }
    }

    /// What the window shows: the chat, or a card before it.
    package enum Screen: Equatable {
        case card(Card)
        case chat(Session)
    }

    package enum Card: Equatable {
        /// Which server to talk to, before any is chosen.
        case address
        case waiting(Waiting)
        case login
    }

    @ObservableState
    package struct State: Equatable {
        /// The server it talks to: none until it's chosen, unless the app comes with its own.
        package var server: Server?
        /// The server's address as it's being written, before one is chosen.
        package var address = ""
        /// Why what was written isn't an address.
        package var addressNotice: String?
        package var connection = Connection.checking
        package var account = Account.unknown
        package var login = LoginForm()
        package var sidebar: SidebarFeature.State = .init()
        package var chat: ChatFeature.State = .init()
        package var objects = ObjectsFeature.State()
        /// The space's pages.
        package var pages = PagesFeature.State()
        /// The page open beside the spaces, in place of the conversation: none while it's the
        /// conversation that's open.
        package var openPage: PageFeature.State?
        /// Who's signed in, and what's remembered about them.
        package var profile = ProfileFeature.State()
        /// The window's panel of spaces and their conversations.
        package var showsSidebar = true

        /// What the View menu's item for the conversations panel says.
        package var sidebarCommand: String { showsSidebar ? "Hide Conversations" : "Show Conversations" }
        /// What the View menu's item for the objects panel says.

        package var screen: Screen {
            guard let server else { return .card(.address) }
            return switch (connection, account) {
            case (.ready, .signedIn(let session)): .chat(session)
            case (.ready, .signedOut): .card(.login)
            case (.ready, .unknown): .card(.waiting(Waiting(connection: .checking, server: server)))
            case (let connection, _): .card(.waiting(Waiting(connection: connection, server: server)))
            }
        }
    }

    package enum Action: BindableAction {
        case binding(BindingAction<State>)
        /// The window appeared: read the saved session and start watching the server.
        case appeared
        case checked(Connection)
        /// The app is active, or isn't: active again, its server is asked again, as someone may
        /// have finished setting it up, or started it.
        case scenePhaseChanged(ScenePhase)
        /// This Mac's own Turgai listens now: it's asked.
        case serverListening
        case sessionLoaded(Session?)
        /// The written address submitted, to talk to the server there.
        case addressSubmitted
        /// Another server to be chosen, in place of the one it was told the address of.
        case changeServerTapped
        case openSetupTapped
        case modeChanged(LoginForm.Mode)
        case submitTapped
        case submitFinished(Result<Session, AccountError>)
        /// The session reached its expiry date.
        case sessionExpired(Session)
        case sidebar(SidebarFeature.Action)
        case chat(ChatFeature.Action)
        case objects(ObjectsFeature.Action)
        case pages(PagesFeature.Action)
        /// The page at `address` open beside the spaces, in place of the conversation.
        case pageOpened(PageAddress)
        /// The open page closed: what it shows is no longer followed.
        case pageClosed
        case openPage(PageFeature.Action)
        case profile(ProfileFeature.Action)
        case sidebarToggled
    }

    private enum CancelID { case expiry, checking }

    @Dependency(\.server) package var server
    @Dependency(\.sessions) package var sessions
    @Dependency(\.serverChoice) package var serverChoice
    @Dependency(\.openURL) package var openURL
    @Dependency(\.continuousClock) package var clock
    @Dependency(\.date.now) package var now

    package var body: some ReducerOf<Self> {
        CombineReducers {
            BindingReducer()
            Scope(\.sidebar, action: \.sidebar) {
                SidebarFeature()
            }
            Scope(\.chat, action: \.chat) {
                ChatFeature()
            }
            Scope(\.objects, action: \.objects) {
                ObjectsFeature()
            }
            Scope(\.pages, action: \.pages) {
                PagesFeature()
            }
            Scope(\.profile, action: \.profile) {
                ProfileFeature()
            }
            Reduce(relay)
                .ifLet(\.openPage, action: \.openPage) {
                    PageFeature()
                }
        }
        // Whoever's signed in: their spaces and conversations heard, and who they are read, until
        // they sign out, whatever window shows.
        .onChange(of: \.account) { before, state in
            switch (before, state.account) {
            case (_, .signedIn(let session)):
                .merge(.send(.sidebar(.signedIn(session))), .send(.profile(.signedIn(session))))
            case (.signedIn, _):
                .send(.sidebar(.signedOut))
            case (_, .signedOut), (_, .unknown):
                .none
            }
        }
        // The space the sidebar shows: its objects, pages and tasks followed, from the first it
        // shows, on a switch, and when the shown one is archived; none while it shows none.
        .onChange(of: \.sidebar.shownSpace?.id) { _, state in
            let space = state.sidebar.shownSpace?.id
            return .merge(
                .send(.objects(.spaceChanged(space))), .send(.pages(.spaceChanged(space))),
                .send(.sidebar(.tasks(.follow(space)))))
        }
    }

    /// What `action` does to the app beyond its features' own: what one says to another.
    private func relay(_ state: inout State, _ action: Action) -> Effect<Action> {
        switch action {
        // The sidebar says what the chat shows; the chat's connection being open again, what the
        // profile reads again.
        case .sidebar(.delegate(.open(let id))):
            // Opened in the space the sidebar lists it in, in place of a page.
            guard let space = state.sidebar.space(of: id) else { return .none }
            state.openPage = nil
            return .send(.chat(.open(id, in: space)))
        case .sidebar(.delegate(.close(let space))):
            return .send(.chat(.close(in: space)))
        case .sidebar(.delegate(.spaceChanged(let space))):
            // Another space: its conversation is what's open, not the last one's page.
            state.openPage = nil
            return .send(.chat(.spaceChanged(space)))

        case .pageOpened(let address):
            // The page that's open already stays as it is.
            guard state.openPage?.address != address else { return .none }
            state.openPage = PageFeature.State(address: address)
            return .send(.openPage(.follow))
        case .pageClosed:
            state.openPage = nil
            return .none
        case .profile(.signOutTapped):
            guard case .signedIn = state.account else { return .none }
            return signOut(&state, notice: nil)

        case .binding, .sidebar, .chat, .objects, .pages, .profile, .openPage:
            return .none

        case .sidebarToggled:
            state.showsSidebar.toggle()
            return .none

        case .appeared:
            return .merge(
                .run { send in await send(.sessionLoaded(sessions.load())) },
                state.server.map { check($0.address) } ?? .none
            )

        case .addressSubmitted:
            guard let address = ServerAddress(written: state.address) else {
                state.addressNotice = "That isn't an address. Write it as a server answers at, like turgai.local:3333."
                return .none
            }
            state.server = .elsewhere(address)
            state.addressNotice = nil
            return .merge(.run { _ in serverChoice.save(address) }, check(address))

        case .changeServerTapped:
            // Before signing in: a server signed in to is left by signing out.
            guard case .elsewhere(let address) = state.server else { return .none }
            if case .signedIn = state.account { return .none }
            state.server = nil
            state.address = address.shown
            state.connection = .checking
            return .merge(.cancel(id: CancelID.checking), .run { _ in serverChoice.clear() })

        case .checked(let connection):
            state.connection = connection
            return .none

        case .scenePhaseChanged(let phase):
            guard phase == .active, let server = state.server else { return .none }
            return check(server.address)

        case .serverListening:
            guard let server = state.server else { return .none }
            return check(server.address)

        case .sessionLoaded(let session):
            guard let session, session.expiresAt > now else {
                state.account = .signedOut
                return .run { _ in sessions.clear() }
            }
            state.account = .signedIn(session)
            // A session says which server it's on, when none was chosen yet.
            var watching = Effect<Action>.none
            if state.server == nil {
                state.server = .elsewhere(session.server)
                watching = .merge(
                    check(session.server), .run { [server = session.server] _ in serverChoice.save(server) })
            }
            // The app's one connection, open while they're signed in, whatever window shows.
            return .merge(watching, expire(session), .send(.chat(.connect(session))))

        case .openSetupTapped:
            guard let address = state.server?.address else { return .none }
            return .run { _ in await openURL(address.url) }

        case .modeChanged(let mode):
            state.login.mode = mode
            state.login.notice = nil
            return .none

        case .submitTapped:
            guard let address = state.server?.address, state.account == .signedOut, state.login.progress == .editing,
                state.login.isFilled
            else { return .none }
            if state.login.mode == .register, let problem = state.login.registrationProblem {
                state.login.notice = problem
                return .none
            }
            state.login.progress = .submitting
            state.login.notice = nil
            return .run {
                [
                    mode = state.login.mode, username = state.login.username,
                    password = state.login.password, passwordAgain = state.login.passwordAgain
                ] send in
                do {
                    let session =
                        switch mode {
                        case .signIn: try await server.signIn(address, username, password)
                        case .register: try await server.register(address, username, password, passwordAgain)
                        }
                    await send(.submitFinished(.success(session)))
                } catch let error as AccountError {
                    await send(.submitFinished(.failure(error)))
                } catch {
                    await send(.submitFinished(.failure(.unavailable(error.localizedDescription))))
                }
            }

        case .submitFinished(.success(let session)):
            state.account = .signedIn(session)
            state.login = LoginForm()
            return .merge(
                .run { _ in sessions.save(session) },
                expire(session),
                .send(.chat(.connect(session)))
            )

        case .submitFinished(.failure(let error)):
            state.login.progress = .editing
            state.login.password = ""
            state.login.passwordAgain = ""
            state.login.notice =
                switch (error, state.login.mode) {
                case (.rejected, .signIn): .invalidCredentials
                case (.rejected, .register): .usernameUnavailable
                case (.unavailable(let reason), _): .unavailable(reason)
                }
            return .none

        case .sessionExpired(let session):
            guard state.account == .signedIn(session) else { return .none }
            return signOut(&state, notice: .sessionEnded)

        }
    }

    /// Signed out: the login form again, saying `notice`, and nothing of the person's kept.
    private func signOut(_ state: inout State, notice: LoginForm.Notice?) -> Effect<Action> {
        state.account = .signedOut
        state.login = LoginForm(notice: notice)
        state.sidebar = SidebarFeature.State()
        state.profile = ProfileFeature.State()
        state.openPage = nil
        return .merge(
            .cancel(id: CancelID.expiry),
            .send(.chat(.disconnect)),
            .run { _ in sessions.clear() }
        )
    }

    /// `address`'s server asked, once, whether it answers and is set up: asked again as something
    /// happens that may change it, never on a timer.
    private func check(_ address: ServerAddress) -> Effect<Action> {
        .run { send in
            let connection: Connection =
                switch try? await server.status(address).setup {
                case .complete: .ready
                case .pending: .setupPending
                case nil: .unreachable
                }
            await send(.checked(connection))
        }
        .cancellable(id: CancelID.checking, cancelInFlight: true)
    }

    /// Sends ``Action/sessionExpired(_:)`` when `session` reaches its expiry date.
    private func expire(_ session: Session) -> Effect<Action> {
        .run { [now] send in
            let remaining = session.expiresAt.timeIntervalSince(now)
            if remaining > 0 {
                try await clock.sleep(for: .seconds(remaining))
            }
            await send(.sessionExpired(session))
        }
        .cancellable(id: CancelID.expiry, cancelInFlight: true)
    }
}

extension AppFeature.State {
    /// The app's first state, talking to `server`, or, with none, to the server it's told.
    package init(server: AppFeature.Server?) {
        self.server = server
    }
}

extension AppFeature {
    /// The app's store, from its first state.
    @MainActor
    package static func store(server: Server?) -> StoreOf<AppFeature> {
        Store(initialState: State(server: server)) {
            AppFeature()
        } withDependencies: {
            prepare(&$0)
        }
    }

    /// What the app needs from the system as it runs, beyond the dependencies' own live values.
    package static func prepare(_ dependencies: inout DependencyValues) {
        // SwiftUI's openURL opens nothing outside a view, so the system is asked itself.
        dependencies.openURL = OpenURLEffect { url in
            await MainActor.run {
                #if os(macOS)
                    NSWorkspace.shared.open(url)
                #else
                    UIApplication.shared.open(url)
                    return true
                #endif
            }
        }
    }
}
