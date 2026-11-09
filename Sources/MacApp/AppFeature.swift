import ComposableArchitecture
import Foundation
import TurgaiModels

/// Waits for the local server to be running and set up, signs in, then runs the chat.
@Reducer
struct AppFeature {
    enum Connection: Equatable, Sendable {
        case checking
        /// Nothing answers yet: the server is still starting, or it stopped.
        case unreachable
        /// The server runs, but onboarding hasn't finished.
        case setupPending
        case ready

        /// What the waiting card says first.
        var title: String {
            switch self {
            case .checking: "Looking for Turgai"
            case .unreachable: "Turgai is starting"
            case .setupPending, .ready: "Almost there"
            }
        }

        /// What the waiting card says next.
        var message: String {
            switch self {
            case .checking: "One moment."
            case .unreachable: "I'll open the chat as soon as it answers. If it stopped, the menu bar says why."
            case .setupPending, .ready:
                "Finish setting up in your browser: an account, a model, and storage. I'll open the chat when you're done."
            }
        }
    }

    enum Account: Equatable, Sendable {
        /// The keychain hasn't been read yet.
        case unknown
        case signedOut
        case signedIn(Session)
    }

    struct LoginForm: Equatable, Sendable {
        enum Mode: Equatable, Sendable {
            case signIn
            /// Create a chat account, then sign in to it.
            case register
        }

        enum Progress: Equatable, Sendable {
            case editing
            case submitting
        }

        /// Why the form is shown, or what went wrong.
        enum Notice: Equatable, Sendable {
            case sessionEnded
            case invalidCredentials
            case invalidUsername
            case weakPassword
            /// The server refused a registration that passed the rules below.
            case usernameUnavailable
            case unavailable(String)

            var text: String {
                switch self {
                case .sessionEnded: "Your session ended. Sign in again."
                case .invalidCredentials: "That username and password didn't match."
                case .invalidUsername: "Choose a username of 3 to 64 letters, numbers, dots, dashes, or underscores."
                case .weakPassword: "Choose a password with at least 12 characters."
                case .usernameUnavailable: "Turgai couldn't create that account. The username may be taken."
                case .unavailable(let reason): "Turgai didn't answer (\(reason)). Try again in a moment."
                }
            }
        }

        var mode = Mode.signIn
        var username = ""
        var password = ""
        var progress = Progress.editing
        var notice: Notice?

        /// What the form is called, and what its button says.
        var title: String {
            switch mode {
            case .signIn: "Sign in"
            case .register: "Create account"
            }
        }

        /// The mode the form switches to.
        var otherMode: Mode {
            switch mode {
            case .signIn: .register
            case .register: .signIn
            }
        }

        /// What the button that switches the mode says.
        var switchPrompt: String {
            switch mode {
            case .signIn: "Create an account"
            case .register: "I have an account"
            }
        }

        var isSubmitting: Bool { progress == .submitting }

        /// Both a username and a password are typed.
        var isFilled: Bool { !username.isEmpty && !password.isEmpty }

        /// What the server would refuse in a registration, checked first so the message is precise.
        /// Mirrors `TurgaiAuth`'s rules; keep them in step.
        var registrationProblem: Notice? {
            let allowed = CharacterSet(
                charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-.")
            if !(3...64).contains(username.count)
                || !username.unicodeScalars.allSatisfy(allowed.contains)
            {
                return .invalidUsername
            }
            if password.count < 12 { return .weakPassword }
            return nil
        }
    }

    /// What the window shows: the chat, or a card before it.
    enum Screen: Equatable {
        case card(Card)
        case chat(Session)
    }

    enum Card: Equatable {
        case waiting(Connection)
        case login
    }

    @ObservableState
    struct State: Equatable {
        var connection = Connection.checking
        var account = Account.unknown
        var login = LoginForm()
        var sidebar = SidebarFeature.State()
        var chat = ChatFeature.State()
        var objects = ObjectsFeature.State()
        /// Who's signed in, and what's remembered about them.
        var profile = ProfileFeature.State()
        /// The window's panel of spaces and their conversations.
        var showsSidebar = true

        /// What the View menu's item for the conversations panel says.
        var sidebarCommand: String { showsSidebar ? "Hide Conversations" : "Show Conversations" }
        /// What the View menu's item for the objects panel says.

        var screen: Screen {
            switch (connection, account) {
            case (.ready, .signedIn(let session)): .chat(session)
            case (.ready, .signedOut): .card(.login)
            case (.ready, .unknown): .card(.waiting(.checking))
            case (let connection, _): .card(.waiting(connection))
            }
        }
    }

    enum Action: BindableAction {
        case binding(BindingAction<State>)
        /// The window appeared: read the saved session and start watching the server.
        case appeared
        case checked(Connection)
        case sessionLoaded(Session?)
        case openSetupTapped
        case modeChanged(LoginForm.Mode)
        case submitTapped
        case submitFinished(Result<Session, AccountError>)
        /// The session reached its expiry date.
        case sessionExpired(Session)
        case sidebar(SidebarFeature.Action)
        case chat(ChatFeature.Action)
        case objects(ObjectsFeature.Action)
        case profile(ProfileFeature.Action)
        case sidebarToggled
    }

    private enum CancelID { case expiry }

    @Dependency(\.server) var server
    @Dependency(\.sessions) var sessions
    @Dependency(\.openURL) var openURL
    @Dependency(\.continuousClock) var clock
    @Dependency(\.date.now) var now

    var body: some ReducerOf<Self> {
        BindingReducer()
        Scope(state: \.sidebar, action: \.sidebar) {
            SidebarFeature()
        }
        Scope(state: \.chat, action: \.chat) {
            ChatFeature()
        }
        Scope(state: \.objects, action: \.objects) {
            ObjectsFeature()
        }
        Scope(state: \.profile, action: \.profile) {
            ProfileFeature()
        }
        Reduce(relay)
    }

    /// What `action` does to the app beyond its features' own: what one says to another.
    private func relay(_ state: inout State, _ action: Action) -> Effect<Action> {
        switch action {
        // The sidebar says what the chat shows; the chat's connection says how the sidebar changes.
        case .sidebar(.delegate(.open(let id))):
            return .send(.chat(.open(id, in: state.sidebar.space(of: id))))
        case .chat(.delegate(.conversationJoined(let conversation))):
            return .send(.sidebar(.conversationJoined(conversation)))
        case .chat(.delegate(.conversationSaid(let conversation))):
            return .send(.sidebar(.conversationSaid(conversation)))
        case .chat(.delegate(.conversationTitled(let conversation))):
            return .send(.sidebar(.conversationTitled(conversation)))
        case .chat(.delegate(.conversationLeft(let id))):
            return .send(.sidebar(.conversationLeft(id)))
        case .chat(.delegate(.memoryChanged)):
            return .send(.profile(.memoryChanged))
        case .chat(.delegate(.connected)):
            return .send(.profile(.connected))

        case .profile(.signOutTapped):
            guard case .signedIn = state.account else { return .none }
            return signOut(&state, notice: nil)

        case .binding, .sidebar, .chat, .objects, .profile:
            return .none

        case .sidebarToggled:
            state.showsSidebar.toggle()
            return .none

        case .appeared:
            return .merge(
                .run { send in await send(.sessionLoaded(sessions.load())) },
                // Keep watching, so the app also notices when the server stops.
                .run { send in
                    while true {
                        let connection: Connection =
                            switch try? await server.status().setup {
                            case .complete: .ready
                            case .pending: .setupPending
                            case nil: .unreachable
                            }
                        await send(.checked(connection))
                        try await clock.sleep(for: .seconds(2))
                    }
                }
            )

        case .checked(let connection):
            state.connection = connection
            return .none

        case .sessionLoaded(let session):
            guard let session, session.expiresAt > now else {
                state.account = .signedOut
                return .run { _ in sessions.clear() }
            }
            state.account = .signedIn(session)
            // The app's one connection, open while they're signed in, whatever window shows.
            return .merge(expire(session), .send(.chat(.connect(session))))

        case .openSetupTapped:
            return .run { _ in await openURL(LocalServer.baseURL) }

        case .modeChanged(let mode):
            state.login.mode = mode
            state.login.notice = nil
            return .none

        case .submitTapped:
            guard state.account == .signedOut, state.login.progress == .editing,
                !state.login.username.isEmpty, !state.login.password.isEmpty
            else { return .none }
            if state.login.mode == .register, let problem = state.login.registrationProblem {
                state.login.notice = problem
                return .none
            }
            state.login.progress = .submitting
            state.login.notice = nil
            let submit =
                switch state.login.mode {
                case .signIn: server.signIn
                case .register: server.register
                }
            return .run { [username = state.login.username, password = state.login.password] send in
                do {
                    await send(.submitFinished(.success(try await submit(username, password))))
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
        return .merge(
            .cancel(id: CancelID.expiry),
            .send(.chat(.disconnect)),
            .run { _ in sessions.clear() }
        )
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

extension AppFeature {
    /// The app's store, from its first state, with the runtime's `objects`.
    @MainActor
    static func store(objects: ObjectsClient) -> StoreOf<AppFeature> {
        Store(initialState: State()) {
            AppFeature()
        } withDependencies: {
            $0.objects = objects
        }
    }
}
