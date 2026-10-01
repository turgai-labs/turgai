import ComposableArchitecture
import Foundation

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
        }

        var mode = Mode.signIn
        var username = ""
        var password = ""
        var progress = Progress.editing
        var notice: Notice?

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

    @ObservableState
    struct State: Equatable {
        var connection = Connection.checking
        var account = Account.unknown
        var login = LoginForm()
        var chat = ChatFeature.State()
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
        case chat(ChatFeature.Action)
    }

    private enum CancelID { case expiry }

    @Dependency(\.server) var server
    @Dependency(\.sessions) var sessions
    @Dependency(\.openURL) var openURL
    @Dependency(\.continuousClock) var clock
    @Dependency(\.date.now) var now

    var body: some ReducerOf<Self> {
        BindingReducer()
        Scope(state: \.chat, action: \.chat) {
            ChatFeature()
        }
        Reduce { state, action in
            switch action {
            case .binding, .chat:
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
                return expire(session)

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
                    expire(session)
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
                state.account = .signedOut
                state.login = LoginForm(notice: .sessionEnded)
                return .merge(
                    .send(.chat(.disconnect)),
                    .run { _ in sessions.clear() }
                )
            }
        }
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
