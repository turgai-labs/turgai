import ComposableArchitecture
import Foundation
import Testing
import TurgaiModels

@testable import MacApp

@MainActor
struct AppFeatureTests {
    let now = Date(timeIntervalSince1970: 1_000_000)

    @Test
    func signedInSessionEndsAtItsExpiry() async {
        let clock = TestClock()
        let session = Session(token: "token", expiresAt: now.addingTimeInterval(60))
        let saved = LockIsolated<[Session]>([])
        let cleared = LockIsolated(0)
        let store = TestStore(
            initialState: AppFeature.State(
                account: .signedOut,
                login: AppFeature.LoginForm(username: "ada", password: "secret")
            )
        ) {
            AppFeature()
        } withDependencies: {
            $0.server.signIn = { _, _ in session }
            $0.sessions.save = { session in saved.withValue { $0.append(session) } }
            $0.sessions.clear = { cleared.withValue { $0 += 1 } }
            $0.chat.disconnect = {}
            $0.continuousClock = clock
            $0.date.now = now
        }

        await store.send(.submitTapped) {
            $0.login.progress = .submitting
        }
        await store.receive(\.submitFinished.success) {
            $0.account = .signedIn(session)
            $0.login = AppFeature.LoginForm()
        }
        #expect(saved.value == [session])

        await clock.advance(by: .seconds(60))
        await store.receive(\.sessionExpired) {
            $0.account = .signedOut
            $0.login = AppFeature.LoginForm(notice: .sessionEnded)
        }
        await store.receive(\.chat.disconnect)
        #expect(cleared.value == 1)
    }

    /// Who's signed in is read for the account button; Sign Out forgets them and the session,
    /// and the expiry it was waiting for no longer signs anyone out.
    @Test
    func signingOutForgetsTheAccount() async {
        let clock = TestClock()
        let session = Session(token: "token", expiresAt: now.addingTimeInterval(60))
        let cleared = LockIsolated(0)
        let store = TestStore(initialState: AppFeature.State(account: .signedOut)) {
            AppFeature()
        } withDependencies: {
            $0.server.me = { _ in Me(id: "account-ada", name: "ada") }
            $0.sessions.clear = { cleared.withValue { $0 += 1 } }
            $0.chat.disconnect = {}
            $0.continuousClock = clock
            $0.date.now = now
        }

        await store.send(.sessionLoaded(session)) { $0.account = .signedIn(session) }
        await store.send(.accountAppeared(session))
        await store.receive(\.meLoaded) { $0.me = Me(id: "account-ada", name: "ada") }
        #expect(store.state.accountInitial == "A")
        await store.send(.signOutTapped) {
            $0.account = .signedOut
            $0.me = nil
        }
        await store.receive(\.chat.disconnect)
        await clock.advance(by: .seconds(60))
        #expect(cleared.value == 1)
    }

    @Test
    func expiredSavedSessionShowsLogin() async {
        let cleared = LockIsolated(0)
        let store = TestStore(initialState: AppFeature.State()) {
            AppFeature()
        } withDependencies: {
            $0.sessions.clear = { cleared.withValue { $0 += 1 } }
            $0.date.now = now
        }

        await store.send(.sessionLoaded(Session(token: "old", expiresAt: now.addingTimeInterval(-1)))) {
            $0.account = .signedOut
        }
        #expect(cleared.value == 1)
    }

    @Test
    func rejectedSignInKeepsTheUsername() async {
        let store = TestStore(
            initialState: AppFeature.State(
                account: .signedOut,
                login: AppFeature.LoginForm(username: "ada", password: "wrong")
            )
        ) {
            AppFeature()
        } withDependencies: {
            $0.server.signIn = { _, _ in throw AccountError.rejected }
        }

        await store.send(.submitTapped) {
            $0.login.progress = .submitting
        }
        await store.receive(\.submitFinished.failure) {
            $0.login = AppFeature.LoginForm(username: "ada", notice: .invalidCredentials)
        }
    }
}

@MainActor
struct RegistrationTests {
    let now = Date(timeIntervalSince1970: 1_000_000)

    @Test
    func registeringSignsInToTheNewAccount() async {
        let session = Session(token: "new", expiresAt: now.addingTimeInterval(60))
        let registered = LockIsolated<[String]>([])
        let store = TestStore(
            initialState: AppFeature.State(
                account: .signedOut,
                login: AppFeature.LoginForm(mode: .register, username: "ada", password: "correct horse battery")
            )
        ) {
            AppFeature()
        } withDependencies: {
            $0.server.register = { username, _ in
                registered.withValue { $0.append(username) }
                return session
            }
            $0.sessions.save = { _ in }
            $0.sessions.clear = {}
            $0.chat.disconnect = {}
            // The expiry timer runs straight through; expiry itself is covered by the sign-in test.
            $0.continuousClock = ImmediateClock()
            $0.date.now = now
        }

        await store.send(.submitTapped) {
            $0.login.progress = .submitting
        }
        await store.receive(\.submitFinished.success) {
            $0.account = .signedIn(session)
            $0.login = AppFeature.LoginForm()
        }
        #expect(registered.value == ["ada"])
        await store.receive(\.sessionExpired) {
            $0.account = .signedOut
            $0.login = AppFeature.LoginForm(notice: .sessionEnded)
        }
        await store.receive(\.chat.disconnect)
    }

    @Test
    func rulesAreCheckedBeforeSending() async {
        let store = TestStore(
            initialState: AppFeature.State(
                account: .signedOut,
                login: AppFeature.LoginForm(mode: .register, username: "ada", password: "short")
            )
        ) {
            AppFeature()
        }

        await store.send(.submitTapped) {
            $0.login.notice = .weakPassword
        }
        await store.send(.binding(.set(\.login.username, "ada lovelace"))) {
            $0.login.username = "ada lovelace"
        }
        await store.send(.submitTapped) {
            $0.login.notice = .invalidUsername
        }
    }

    @Test
    func refusedRegistrationSaysTheNameMayBeTaken() async {
        let store = TestStore(
            initialState: AppFeature.State(
                account: .signedOut,
                login: AppFeature.LoginForm(mode: .register, username: "ada", password: "correct horse battery")
            )
        ) {
            AppFeature()
        } withDependencies: {
            $0.server.register = { _, _ in throw AccountError.rejected }
        }

        await store.send(.submitTapped) {
            $0.login.progress = .submitting
        }
        await store.receive(\.submitFinished.failure) {
            $0.login = AppFeature.LoginForm(mode: .register, username: "ada", notice: .usernameUnavailable)
        }
    }
}

@MainActor
struct ChatFeatureTests {
    /// A bubble leans as the web's does for the same message: between −2.4° and 2.4°.
    @Test
    func aBubbleLeansAsOnTheWeb() {
        #expect(MessageID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!).lean.degrees == 1.6)
        #expect(MessageID(rawValue: UUID(uuidString: "E621E1F8-C36C-495A-93FC-0C247A3E6E5F")!).lean.degrees == 1.9)
        #expect((0..<200).map { _ in MessageID().lean.degrees }.allSatisfy { (-2.4...2.4).contains($0) })
    }

    /// A short stamp takes its whole lean; a long one leans less, so its ends lift 6 points apart
    /// at most.
    @Test
    func aLongStampLeansLess() {
        #expect(Lean(degrees: -2).angle(across: 60) == .degrees(-2))
        let long = Lean(degrees: 2).angle(across: 600)
        #expect(abs(600 * sin(long.radians) - 6) < 0.001)
    }

    @Test
    func sentMessageIsPendingUntilAccepted() async {
        let sent = LockIsolated<[ChatCommand]>([])
        let store = TestStore(
            initialState: ChatFeature.State(
                connection: .connected(botID: BotID(rawValue: "turgai")), conversationID: ConversationID(rawValue: "c"),
                draft: " hi ")
        ) {
            ChatFeature()
        } withDependencies: {
            $0.chat.send = { request in sent.withValue { $0.append(request) } }
            $0.uuid = .incrementing
        }

        let request = SendMessageRequest(id: MessageID(rawValue: UUID(0)), text: "hi")
        await store.send(.sendTapped) {
            $0.draft = ""
            $0.pending = [request]
        }
        #expect(sent.value == [.message(request)])

        let accepted = Message(id: request.id, role: .user, text: "hi")
        await store.send(
            .received(
                ChatEvent(
                    payload: .messageAccepted(
                        conversationID: ConversationID(rawValue: "c"), turnID: nil, message: accepted))
            )
        ) {
            $0.pending = []
            $0.messages = [accepted]
        }
    }

    @Test
    func anAccessRequestIsAskedOnceAndAnswered() async {
        let sent = LockIsolated<[ChatCommand]>([])
        let conversation = ConversationID(rawValue: "c")
        let store = TestStore(
            initialState: ChatFeature.State(
                connection: .connected(botID: BotID(rawValue: "turgai")), conversationID: conversation)
        ) {
            ChatFeature()
        } withDependencies: {
            $0.chat.send = { command in sent.withValue { $0.append(command) } }
        }
        let forecast = AccessRequest(id: UUID(1), request: "GET https://api.open-meteo.com/v1/forecast")
        let search = AccessRequest(id: UUID(2), request: "GET https://html.duckduckgo.com/html/?q=tea")

        await store.send(
            .received(ChatEvent(payload: .accessRequested(conversationID: conversation, request: forecast)))
        ) {
            $0.accessRequests = [forecast]
        }
        // A reconnect shows it again; it stays one request.
        await store.send(
            .received(ChatEvent(payload: .accessRequested(conversationID: conversation, request: forecast))))
        await store.send(.received(ChatEvent(payload: .accessRequested(conversationID: conversation, request: search))))
        {
            $0.accessRequests = [forecast, search]
        }

        await store.send(.accessAnswered(forecast.id, .always)) {
            $0.accessRequests = [search]
        }
        #expect(sent.value == [.answer(id: forecast.id, answer: .always)])

        // Answered in another client.
        await store.send(
            .received(
                ChatEvent(payload: .accessAnswered(conversationID: conversation, requestID: search.id, answer: .no)))
        ) {
            $0.accessRequests = []
        }
    }
}

@MainActor
struct ShownMessageTests {
    /// A person's message other than yours says who wrote it; an agent's reply has the turn that
    /// made it, shown beside it once its ⓘ is tapped.
    @Test
    func aMessageShowsWhoWroteItAndTheTurnThatMadeIt() {
        let ann = ParticipantSummary(kind: .person, id: "account-ann", name: "ann")
        let bob = ParticipantSummary(kind: .person, id: "account-bob", name: "bob")
        let reply = MessageID(rawValue: UUID(2))
        let turn = TurnRecord(
            id: TurnID(rawValue: reply.rawValue), message: "pasta?", startedAt: Date(timeIntervalSince1970: 0))
        var state = ChatFeature.State(
            you: "account-ann",
            messages: [
                Message(id: MessageID(rawValue: UUID(0)), role: .user, text: "pasta?", author: ann),
                Message(id: MessageID(rawValue: UUID(1)), role: .user, text: "yes", author: bob),
                Message(id: reply, role: .assistant, text: "Here's one."),
            ],
            turns: [turn])

        #expect(state.shown.map(\.someoneElse) == [nil, "bob", nil])
        #expect(state.shown.map(\.turn) == [nil, nil, turn])
        #expect(state.shown.map(\.showsTurn) == [false, false, false])
        state.shownTurn = reply
        #expect(state.shown.map(\.showsTurn) == [false, false, true])
    }
}

struct ScreenTests {
    /// The chat once the server is ready and someone is signed in; a card before.
    @Test
    func theWindowShowsTheChatOnlyWhenReadyAndSignedIn() {
        let session = Session(token: "t", expiresAt: Date(timeIntervalSince1970: 0))
        var state = AppFeature.State(connection: .setupPending, account: .signedIn(session))
        #expect(state.screen == .card(.waiting(.setupPending)))
        state.connection = .ready
        #expect(state.screen == .chat(session))
        state.account = .unknown
        #expect(state.screen == .card(.waiting(.checking)))
        state.account = .signedOut
        #expect(state.screen == .card(.login))
    }
}
