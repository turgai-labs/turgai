import ComposableArchitecture
import Foundation
import SwiftUI
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
            $0.chat.connect = { _ in AsyncThrowingStream { _ in } }
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
        await store.receive(\.chat.connect) { $0.chat.session = session }
        await store.receive(\.chat.delegate, .connected)
        await store.receive(\.profile.connected)

        await clock.advance(by: .seconds(60))
        await store.receive(\.sessionExpired) {
            $0.account = .signedOut
            $0.login = AppFeature.LoginForm(notice: .sessionEnded)
        }
        await store.receive(\.chat.disconnect) { $0.chat = ChatFeature.State() }
        #expect(cleared.value == 1)
    }

    /// Signed in, the app's one connection opens; who's signed in is read for the account button;
    /// Sign Out on the profile forgets them and the session, closes the connection, and the expiry
    /// it was waiting for no longer signs anyone out.
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
            // Open until it's closed.
            $0.chat.connect = { _ in AsyncThrowingStream { _ in } }
            $0.chat.disconnect = {}
            $0.continuousClock = clock
            $0.date.now = now
        }

        await store.send(.sessionLoaded(session)) { $0.account = .signedIn(session) }
        await store.receive(\.chat.connect) { $0.chat.session = session }
        await store.receive(\.chat.delegate, .connected)
        await store.receive(\.profile.connected)
        await store.send(.profile(.appeared(session))) { $0.profile.session = session }
        await store.receive(\.profile.meLoaded) { $0.profile.me = Me(id: "account-ada", name: "ada") }
        #expect(store.state.profile.initial == "A")
        await store.send(.profile(.signOutTapped)) {
            $0.account = .signedOut
            $0.profile = ProfileFeature.State()
        }
        await store.receive(\.chat.disconnect) { $0.chat = ChatFeature.State() }
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
        let clock = TestClock()
        let session = Session(token: "new", expiresAt: now.addingTimeInterval(60))
        let registered = LockIsolated<[String]>([])
        let store = TestStore(
            initialState: AppFeature.State(
                account: .signedOut,
                login: AppFeature.LoginForm(
                    mode: .register, username: "ada", password: "correct horse battery",
                    passwordAgain: "correct horse battery")
            )
        ) {
            AppFeature()
        } withDependencies: {
            $0.server.register = { username, _, _ in
                registered.withValue { $0.append(username) }
                return session
            }
            $0.sessions.save = { _ in }
            $0.sessions.clear = {}
            $0.chat.connect = { _ in AsyncThrowingStream { _ in } }
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
        #expect(registered.value == ["ada"])
        await store.receive(\.chat.connect) { $0.chat.session = session }
        await store.receive(\.chat.delegate, .connected)
        await store.receive(\.profile.connected)
        await clock.advance(by: .seconds(60))
        await store.receive(\.sessionExpired) {
            $0.account = .signedOut
            $0.login = AppFeature.LoginForm(notice: .sessionEnded)
        }
        await store.receive(\.chat.disconnect) { $0.chat = ChatFeature.State() }
    }

    @Test
    func rulesAreCheckedBeforeSending() async {
        let store = TestStore(
            initialState: AppFeature.State(
                account: .signedOut,
                login: AppFeature.LoginForm(mode: .register, username: "ada", password: "short", passwordAgain: "short")
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

    /// A new password typed differently the second time is caught before anything's sent.
    @Test
    func differingPasswordsAreCaughtBeforeRegistering() async {
        let store = TestStore(
            initialState: AppFeature.State(
                account: .signedOut,
                login: AppFeature.LoginForm(
                    mode: .register, username: "ada", password: "correct horse battery",
                    passwordAgain: "correct horse battey")
            )
        ) {
            AppFeature()
        }

        await store.send(.submitTapped) {
            $0.login.notice = .passwordsDiffer
        }
    }

    @Test
    func refusedRegistrationSaysTheNameMayBeTaken() async {
        let store = TestStore(
            initialState: AppFeature.State(
                account: .signedOut,
                login: AppFeature.LoginForm(
                    mode: .register, username: "ada", password: "correct horse battery",
                    passwordAgain: "correct horse battery")
            )
        ) {
            AppFeature()
        } withDependencies: {
            $0.server.register = { _, _, _ in throw AccountError.rejected }
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

    /// Shift-Return starts a new line where the cursor is, instead of what's selected, and puts the
    /// cursor after it; with no cursor yet, at the end.
    @Test
    func shiftReturnStartsANewLineAtTheCursor() async {
        /// What a new line typed into `draft`, its cursor or selection where `selection` puts it, leaves.
        func typing(into draft: String, at selection: (String) -> TextSelection?) async -> (String, TextSelection?) {
            var state = ChatFeature.State()
            state.draft = draft
            state.draftSelection = selection(draft)
            let store = TestStore(initialState: state) { ChatFeature() }
            store.exhaustivity = .off
            await store.send(.newLineTyped)
            return (store.state.draft, store.state.draftSelection)
        }

        let (atCursor, cursor) = await typing(into: "ab") {
            TextSelection(insertionPoint: $0.index(after: $0.startIndex))
        }
        #expect(atCursor == "a\nb")
        #expect(cursor == TextSelection(insertionPoint: atCursor.index(atCursor.startIndex, offsetBy: 2)))

        let (overSelection, _) = await typing(into: "ab") { TextSelection(range: $0.range(of: "b")!) }
        #expect(overSelection == "a\n")

        let (atEnd, end) = await typing(into: "ab") { _ in nil }
        #expect(atEnd == "ab\n")
        #expect(end == TextSelection(insertionPoint: atEnd.endIndex))
    }

    /// A short stamp takes its whole lean; a long one leans less, so its ends lift 6 points apart
    /// at most.
    @Test
    func aLongStampLeansLess() {
        #expect(Lean(degrees: -2).angle(across: 60) == .degrees(-2))
        let long = Lean(degrees: 2).angle(across: 600)
        #expect(abs(600 * sin(long.radians) - 6) < 0.001)
    }

    /// A message taken while the connection was away is said once history has it: it's sending no
    /// more.
    @Test
    func historyEndsSendingWhatItHas() async {
        let request = SendMessageRequest(id: MessageID(rawValue: UUID(0)), text: "hi")
        let taken = Message(id: request.id, role: .user, text: "hi", at: Date(timeIntervalSince1970: 1))
        let store = TestStore(
            initialState: ChatFeature.State(
                connection: .connected(botID: BotID(rawValue: "turgai")), conversationID: ConversationID(rawValue: "c"),
                pending: [request])
        ) {
            ChatFeature()
        } withDependencies: {
            $0.date = .constant(Date(timeIntervalSince1970: 2))
        }

        await store.send(
            .received(ChatEvent(payload: .history(conversationID: ConversationID(rawValue: "c"), messages: [taken])))
        ) {
            $0.today = Date(timeIntervalSince1970: 2)
            $0.messages = [taken]
            $0.pending = []
        }
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
            $0.date = .constant(Date(timeIntervalSince1970: 2))
        }

        let request = SendMessageRequest(id: MessageID(rawValue: UUID(0)), text: "hi")
        await store.send(.sendTapped) {
            $0.draft = ""
            $0.pending = [request]
        }
        #expect(sent.value == [.message(request)])

        let accepted = Message(id: request.id, role: .user, text: "hi", at: Date(timeIntervalSince1970: 1))
        await store.send(
            .received(
                ChatEvent(
                    payload: .messageAccepted(
                        conversationID: ConversationID(rawValue: "c"), turnID: nil, message: accepted))
            )
        ) {
            $0.pending = []
            $0.today = Date(timeIntervalSince1970: 2)
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
    /// 9 November 2026 at `hour`:`minute`, or `days` before.
    private func on(hour: Int, minute: Int = 0, daysBefore days: Int = 0) -> Date {
        let day = Calendar.current.date(
            from: DateComponents(year: 2026, month: 11, day: 9, hour: hour, minute: minute))!
        return Calendar.current.date(byAdding: .day, value: -days, to: day)!
    }

    /// With more than one person in it, each message says who said it, you as You, and when; an
    /// agent's reply has the turn that made it, shown beside it once its ⓘ is tapped.
    @Test
    func eachMessageSaysWhoSaidItAndWhen() {
        let ann = ParticipantSummary(kind: .person, id: "account-ann", name: "ann")
        let bob = ParticipantSummary(kind: .person, id: "account-bob", name: "bob")
        let turgai = ParticipantSummary(kind: .agent, id: "turgai", name: "Turgai")
        let reply = MessageID(rawValue: UUID(2))
        let at = on(hour: 14, minute: 3)
        let turn = TurnRecord(id: TurnID(rawValue: reply.rawValue), message: "pasta?", startedAt: at)
        var state = ChatFeature.State(
            participants: [ann, bob, turgai],
            you: "account-ann",
            messages: [
                Message(id: MessageID(rawValue: UUID(0)), role: .user, text: "pasta?", author: ann, at: at),
                Message(id: MessageID(rawValue: UUID(1)), role: .user, text: "yes", author: bob, at: at),
                Message(id: reply, role: .assistant, text: "Here's one.", author: turgai, at: at),
            ],
            turns: [turn])
        state.today = on(hour: 18)

        let time = at.formatted(date: .omitted, time: .shortened)
        #expect(state.shown.map(\.whose) == [.yours, .someoneElse, .agent])
        #expect(state.shown.map(\.caption) == ["You · \(time)", "bob · \(time)", "Turgai · \(time)"])
        #expect(state.shown.map(\.turn) == [nil, nil, turn])
        #expect(state.shown.map(\.showsTurn) == [false, false, false])
        state.shownTurn = reply
        #expect(state.shown.map(\.showsTurn) == [false, false, true])

        // Only you and the agent: no one's named.
        state.participants = [ann, turgai]
        state.messages.remove(at: 1)
        #expect(state.shown.map(\.caption) == [time, time])
    }

    /// A message you send is shown at once, faded and sending, and stays the same row once it's
    /// said, then saying when.
    @Test
    func aMessageYouSendIsTheRowItBecomes() {
        let request = SendMessageRequest(id: MessageID(rawValue: UUID(0)), text: "hi")
        var state = ChatFeature.State(pending: [request])
        state.today = on(hour: 18)
        #expect(state.shown.map(\.id) == [request.id])
        #expect(state.shown.map(\.delivery) == [.sending])
        #expect(state.shown.map(\.caption) == ["sending…"])

        let said = on(hour: 14)
        state.messages = [Message(id: request.id, role: .user, text: "hi", at: said)]
        #expect(state.shown.map(\.id) == [request.id])
        #expect(state.shown.map(\.delivery) == [.said])
        #expect(state.shown.map(\.caption) == [said.formatted(date: .omitted, time: .shortened)])
    }

    /// A time today says only the time; in the six days before, its weekday too; before that, its
    /// date.
    @Test
    func aTimeSaysAsMuchOfItsDayAsItNeeds() {
        let today = on(hour: 18)
        let earlier = on(hour: 9)
        let monday = on(hour: 9, daysBefore: 3)
        let lastWeek = on(hour: 9, daysBefore: 10)

        #expect(ChatFeature.State.when(earlier, today: today) == earlier.formatted(date: .omitted, time: .shortened))
        #expect(
            ChatFeature.State.when(monday, today: today)
                == monday.formatted(.dateTime.weekday(.abbreviated).hour().minute()))
        #expect(
            ChatFeature.State.when(lastWeek, today: today)
                == lastWeek.formatted(.dateTime.day().month(.abbreviated).hour().minute()))
    }

    /// The reply being typed is the last message shown, under the id it's said with, typing until
    /// it's said: then it's the same message, there once, saying when. Before it's typed, what the
    /// agent does shows instead.
    @Test
    func theReplyBeingTypedIsTheMessageItBecomes() {
        let asked = on(hour: 14)
        let question = Message(id: MessageID(rawValue: UUID(0)), role: .user, text: "pasta?", at: asked)
        let reply = MessageID(rawValue: UUID(1))
        var state = ChatFeature.State(messages: [question], turn: ChatFeature.Turn())
        state.today = on(hour: 18)
        #expect(state.working == "Thinking…")
        state.turn = ChatFeature.Turn(activity: "Using search…")
        #expect(state.working == "Using search…")

        state.turn = ChatFeature.Turn(phase: .typing, partial: ReplySoFar(id: reply, text: "Here"))
        #expect(state.shown.map(\.id) == [question.id, reply])
        #expect(state.shown.last?.text == "Here")
        #expect(state.shown.last?.caption == "typing…")
        #expect(state.working == nil)

        let said = on(hour: 14, minute: 1)
        state.messages.append(Message(id: reply, role: .assistant, text: "Here's one.", at: said))
        #expect(state.shown.map(\.id) == [question.id, reply])
        #expect(state.shown.last?.text == "Here's one.")
        #expect(state.shown.last?.caption == said.formatted(date: .omitted, time: .shortened))
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
