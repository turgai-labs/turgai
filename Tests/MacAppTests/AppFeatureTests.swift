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
    @Test
    func sentMessageIsPendingUntilAccepted() async {
        let sent = LockIsolated<[ChatCommand]>([])
        let store = TestStore(
            initialState: ChatFeature.State(connection: .connected(botID: BotID(rawValue: "turgai")), draft: " hi ")
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
    func approvalIsAskedOnceAndAnswered() async {
        let sent = LockIsolated<[ChatCommand]>([])
        let store = TestStore(
            initialState: ChatFeature.State(connection: .connected(botID: BotID(rawValue: "turgai")))
        ) {
            ChatFeature()
        } withDependencies: {
            $0.chat.send = { command in sent.withValue { $0.append(command) } }
        }
        let conversation = ConversationID(rawValue: "c")
        let play = Approval(id: UUID(1), action: "Music.play", arguments: #"{"query":"Daft Punk"}"#)
        let add = Approval(id: UUID(2), action: "Reminders.add", arguments: #"{"title":"Milk"}"#)

        await store.send(
            .received(ChatEvent(payload: .approvalRequested(conversationID: conversation, turnID: nil, approval: play)))
        ) {
            $0.approvals = [play]
        }
        // A reconnect asks again; it stays one question.
        await store.send(
            .received(ChatEvent(payload: .approvalRequested(conversationID: conversation, turnID: nil, approval: play)))
        )
        await store.send(
            .received(ChatEvent(payload: .approvalRequested(conversationID: conversation, turnID: nil, approval: add)))
        ) {
            $0.approvals = [play, add]
        }

        await store.send(.approvalAnswered(play.id, .granted)) {
            $0.approvals = [add]
        }
        #expect(sent.value == [.approval(id: play.id, decision: .granted)])

        // Answered in another client.
        await store.send(
            .received(
                ChatEvent(
                    payload: .approvalResolved(conversationID: conversation, approvalID: add.id, decision: .denied)))
        ) {
            $0.approvals = []
        }
    }
}
