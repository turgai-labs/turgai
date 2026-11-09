import ComposableArchitecture
import Foundation
import SwiftUI
import TurgaiModels

/// The open conversation, over the app's one connection: its history, live turns, and sending; and
/// what the connection says about the person's other conversations, passed on.
@Reducer
struct ChatFeature {
    enum Connection: Equatable, Sendable {
        case connecting
        case connected(botID: BotID)
        /// The socket closed, and why; the feature reconnects shortly.
        case disconnected(why: String)
    }

    /// What the bot is doing in the current turn.
    struct Turn: Equatable, Sendable {
        var phase: ConversationPhase?
        /// Tool or provider narration, such as the tool being used.
        var activity: String?
        /// The reply so far, while it's typed.
        var partial: ReplySoFar?
    }

    @ObservableState
    struct State: Equatable {
        var connection = Connection.connecting
        /// Who it's for, once it connects.
        var session: Session?
        /// The conversation it shows: none until the window opens one.
        var conversationID: ConversationID?
        /// The space it's in, as it was when it was opened, and as it's changed since.
        var space: SpaceSummary?
        /// Who's in it: its agent and its people.
        var participants: [ParticipantSummary] = []
        /// The people in its space: who `@` can bring in.
        var spacePeople: [SpacePerson] = []
        /// Who the draft is said to, as picked from `@`'s suggestions: none for no one in particular.
        var to: [ParticipantSummary] = []
        /// The id of the person this app is, as the conversation says: their own messages are theirs.
        var you: String?
        var messages: [Message] = []
        /// Sent, but not yet accepted by the conversation.
        var pending: [SendMessageRequest] = []
        var turn: Turn?
        /// Actions waiting for the user's consent, oldest first.
        var accessRequests: IdentifiedArrayOf<AccessRequest> = []
        var draft = ""
        /// Where the cursor is in the draft, or what's selected: none until the field says, or
        /// after the draft is changed here.
        var draftSelection: TextSelection?
        var error: ChatError?
        /// The agent's turns, step by step: the past ones, then each new one as it runs.
        var turns: IdentifiedArrayOf<TurnRecord> = []

        /// The suggestion ↑ or ↓ last marked: none until one does.
        var marked: ParticipantSummary?
        /// The reply whose turn is shown beside it: none while none is.
        var shownTurn: MessageID?
        /// When its messages last changed: what their times are said against.
        var today = Date.distantPast

        /// What was said, the reply being typed, then what you've sent that isn't taken yet: a
        /// message's row stays the same once it's said, so it isn't drawn again. Each says when it
        /// was said, and who said it while more than one person is in it, or has said something in it.
        var shown: [ShownMessage] {
            let named =
                participants.filter { $0.kind == .person }.count > 1 || messages.contains { whose($0) == .someoneElse }
            let said = messages.map { message in
                let whose = whose(message)
                let name = whose == .yours ? "You" : message.author?.name
                return shown(
                    message.id, whose: whose, text: message.text, name: named ? name : nil,
                    when: Self.when(message.at, today: today), delivery: .said)
            }
            let typing = turn?.partial.flatMap { typed in
                messages.contains { $0.id == typed.id }
                    ? nil
                    : shown(
                        typed.id, whose: .agent, text: typed.text, name: named ? typed.author?.name : nil,
                        when: "typing…", delivery: .said)
            }
            let sending = pending.filter { request in !messages.contains { $0.id == request.id } }.map { request in
                shown(
                    request.id, whose: .yours, text: request.text, name: named ? "You" : nil, when: "sending…",
                    delivery: .sending)
            }
            return said + (typing.map { [$0] } ?? []) + sending
        }

        /// Whose `message` is, as it's drawn.
        private func whose(_ message: Message) -> Whose {
            switch (message.role, message.author) {
            case (.assistant, _): .agent
            case (.user, let author?) where author.kind == .person && author.id != you: .someoneElse
            case (.user, _): .yours
            }
        }

        /// The message `id`, with the agent's turn that made it, when it's a reply of the agent's.
        private func shown(
            _ id: MessageID, whose: Whose, text: String, name: String?, when: String, delivery: Delivery
        ) -> ShownMessage {
            let turn = whose == .agent ? turns[id: TurnID(rawValue: id.rawValue)] : nil
            let caption = ((name.map { [$0] } ?? []) + [when]).joined(separator: " · ")
            return ShownMessage(
                id: id, whose: whose, text: text, caption: caption, delivery: delivery, turn: turn,
                showsTurn: turn != nil && shownTurn == id)
        }

        /// When `at` was, as a caption says it on `today`: its time that day, its weekday and time in
        /// the six days before, its date and time before that.
        static func when(_ at: Date, today: Date) -> String {
            let calendar = Calendar.current
            let day = calendar.startOfDay(for: at)
            switch calendar.dateComponents([.day], from: day, to: calendar.startOfDay(for: today)).day {
            case 0:
                return at.formatted(date: .omitted, time: .shortened)
            case let days? where (1...6).contains(days):
                return at.formatted(.dateTime.weekday(.abbreviated).hour().minute())
            default:
                return at.formatted(.dateTime.day().month(.abbreviated).hour().minute())
            }
        }

        /// What the agent is doing before its reply is typed: none while no turn runs, or once its
        /// reply shows.
        var working: String? {
            guard let turn, turn.partial == nil else { return nil }
            return turn.activity ?? (turn.phase == .typing ? "Typing…" : "Thinking…")
        }

        /// Who's in it, as the line under its name says them: you first, as You, then the others.
        var participantsLine: String {
            let others = participants.filter { $0.id != you }.map(\.name)
            return ((participants.contains { $0.id == you } ? ["You"] : []) + others).joined(separator: ", ")
        }

        /// What's wrong with the connection, while something is: none while it's connected.
        var connectionNotice: String? {
            switch connection {
            case .connected: nil
            case .connecting: "Connecting…"
            case .disconnected: "Reconnecting…"
            }
        }

        /// What's under the messages: the composer, or, once its space is archived, that nothing new
        /// is said in it.
        var writing: Writing {
            space?.status == .archived
                ? .closed("This space is archived: its conversations can be read, and nothing new is said in them.")
                : .composer
        }

        /// Something's typed, and there's a connection to send it on.
        var canSend: Bool {
            guard case .connected = connection else { return false }
            return !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        /// The suggestion Return or Tab picks: the one marked, while it's still suggested, or else
        /// the first; none while `@` suggests no one.
        var picked: ParticipantSummary? {
            suggestions.first { $0 == marked } ?? suggestions.first
        }

        /// Who the `@` being typed could be, whose name starts with what's typed after it: the
        /// participants but you, then the people in its space who aren't in it, whom mentioning
        /// brings in.
        var suggestions: [ParticipantSummary] {
            guard let typed = typedMention?.dropFirst().lowercased() else { return [] }
            let inIt = Set(participants.map(\.id))
            let outside = spacePeople.filter { !inIt.contains($0.id) && $0.id != you }
                .map { ParticipantSummary(kind: .person, id: $0.id, name: $0.name) }
            return (participants.filter { $0.id != you } + outside).filter { $0.name.lowercased().hasPrefix(typed) }
        }

        /// The suggestions as they're shown: the one Return picks marked, and who'd join by it.
        var shownSuggestions: [ShownSuggestion] {
            let inIt = Set(participants.map(\.id))
            return suggestions.map {
                ShownSuggestion(participant: $0, isPicked: $0 == picked, joins: !inIt.contains($0.id))
            }
        }

        /// The `@` the draft ends in, with what's typed after it: none when it doesn't end in one.
        fileprivate var typedMention: Substring? {
            guard let at = draft.lastIndex(of: "@"),
                at == draft.startIndex || draft[draft.index(before: at)].isWhitespace
            else { return nil }
            let typed = draft[at...]
            return typed.contains(where: \.isNewline) ? nil : typed
        }
    }

    enum Action: BindableAction {
        case binding(BindingAction<State>)
        case connect(Session)
        /// Show `id`, in `space`, instead of the conversation shown before.
        case open(ConversationID, in: SpaceSummary?)
        /// Show no conversation, in `space`, which has none to show.
        case close(in: SpaceSummary)
        /// A space is as `space` says now.
        case spaceChanged(SpaceSummary)
        case participantsLoaded([ParticipantSummary])
        case spacePeopleLoaded([SpacePerson])
        /// ⓘ beside a reply: its turn is shown.
        case turnTapped(MessageID)
        case turnDismissed
        /// `participant` was picked from `@`'s suggestions: the draft is said to them.
        case mentioned(ParticipantSummary)
        /// Return in the message field: picks the suggestion marked while `@` suggests someone,
        /// sends the draft otherwise.
        case submitted
        /// Shift-Return in the message field: a new line where the cursor is, instead of what's
        /// selected.
        case newLineTyped
        /// ↑ or ↓ while `@` suggests someone: the mark moves `step` suggestions, round the list.
        case markMoved(by: Int)
        case disconnect
        case received(ChatEvent)
        case closed(why: String)
        case sendTapped
        case sendFailed(SendMessageRequest)
        case accessAnswered(AccessRequest.ID, AccessAnswer)
        case delegate(Delegate)

        /// What the connection says about the person's conversations and memory, for the window,
        /// and that it's open again.
        enum Delegate: Equatable {
            case conversationJoined(Conversation)
            case conversationSaid(Conversation)
            case conversationTitled(Conversation)
            case conversationLeft(ConversationID)
            case conversationDeleted(ConversationID)
            /// What's remembered about them changed.
            case memoryChanged
            /// The connection is open, again or for the first time: what's joined is joined again.
            case connected
        }
    }

    private enum CancelID { case socket }

    @Dependency(\.chat) var chat
    @Dependency(\.server) var server
    @Dependency(\.continuousClock) var clock
    @Dependency(\.date.now) var now
    @Dependency(\.uuid) var uuid

    var body: some ReducerOf<Self> {
        BindingReducer()
        Reduce { state, action in
            switch action {
            case .binding, .delegate:
                return .none

            case .connect(let session):
                state.connection = .connecting
                state.session = session
                return .run { [shown = state.conversationID] send in
                    let why: String
                    do {
                        let events = await chat.connect(session)
                        // A connection made again shows what was shown before.
                        if let shown { try await chat.send(.open(conversationID: shown)) }
                        await send(.delegate(.connected))
                        for try await event in events {
                            await send(.received(event))
                        }
                        why = "The server closed the connection."
                    } catch {
                        why = error.localizedDescription
                    }
                    await send(.closed(why: why))
                    // Reconnect after a pause, unless cancelled by `.disconnect`.
                    try await clock.sleep(for: .seconds(2))
                    await send(.connect(session))
                }
                .cancellable(id: CancelID.socket, cancelInFlight: true)

            case .disconnect:
                state = State()
                return .merge(
                    .cancel(id: CancelID.socket),
                    .run { _ in await chat.disconnect() }
                )

            case .closed(let why):
                state.connection = .disconnected(why: why)
                state.turn = nil
                // The conversation asks again when the socket reconnects.
                state.accessRequests = []
                return .none

            case .open(let id, let space):
                guard id != state.conversationID else { return .none }
                state = State(connection: state.connection, session: state.session, conversationID: id, space: space)
                return .merge(
                    .run { _ in try? await chat.send(.open(conversationID: id)) },
                    loadParticipants(of: id, as: state.session),
                    loadSpacePeople(of: space, as: state.session)
                )

            case .close(let space):
                state = State(connection: state.connection, session: state.session, space: space)
                return .none

            case .spaceChanged(let space):
                guard state.space?.id == space.id else { return .none }
                state.space = space
                return .none

            case .participantsLoaded(let participants):
                state.participants = participants
                return .none

            case .spacePeopleLoaded(let people):
                state.spacePeople = people
                return .none

            case .turnTapped(let id):
                state.shownTurn = id
                return .none

            case .turnDismissed:
                state.shownTurn = nil
                return .none

            case .mentioned(let participant):
                mention(participant, in: &state)
                return .none

            case .submitted:
                guard let picked = state.picked else { return send(&state) }
                mention(picked, in: &state)
                return .none

            case .newLineTyped:
                let end = state.draft.endIndex
                let range =
                    if case .selection(let range)? = state.draftSelection?.indices, range.upperBound <= end {
                        range
                    } else {
                        end..<end
                    }
                let before = state.draft.distance(from: state.draft.startIndex, to: range.lowerBound)
                state.draft.replaceSubrange(range, with: "\n")
                state.draftSelection = TextSelection(
                    insertionPoint: state.draft.index(state.draft.startIndex, offsetBy: before + 1))
                return .none

            case .markMoved(let step):
                let suggestions = state.suggestions
                guard let picked = state.picked, let at = suggestions.firstIndex(of: picked) else { return .none }
                state.marked = suggestions[(at + step + suggestions.count) % suggestions.count]
                return .none

            case .received(let event):
                switch event.payload {
                case .conversationJoined(let conversation):
                    return .send(.delegate(.conversationJoined(conversation)))
                case .conversationSaid(let conversation):
                    return .send(.delegate(.conversationSaid(conversation)))
                case .conversationTitled(let conversation):
                    return .send(.delegate(.conversationTitled(conversation)))
                case .conversationLeft(let id):
                    return .send(.delegate(.conversationLeft(id)))
                case .conversationDeleted(let id):
                    return .send(.delegate(.conversationDeleted(id)))
                case .memoryChanged:
                    return .send(.delegate(.memoryChanged))
                case .reply:
                    // The client hands replies to what pushed them: none comes here.
                    return .none
                default:
                    // Only the shown conversation's: one shown before may still be heard a moment.
                    guard event.conversationID == nil || event.conversationID == state.conversationID else {
                        return .none
                    }
                    // A message of yours that brought someone in: who's in it is read again.
                    let broughtIn = Self.bringsIn(event.payload, in: state)
                    apply(event.payload, to: &state)
                    guard broughtIn, let id = state.conversationID else { return .none }
                    return loadParticipants(of: id, as: state.session)
                }

            case .sendTapped:
                return send(&state)

            case .accessAnswered(let id, let answer):
                guard state.accessRequests.remove(id: id) != nil else { return .none }
                return .run { _ in
                    // Unanswered, the request expires as a denial on the server.
                    try? await chat.send(.answer(id: id, answer: answer))
                }

            case .sendFailed(let request):
                state.pending.removeAll { $0.id == request.id }
                if state.draft.isEmpty {
                    state.draft = request.text
                    state.draftSelection = nil
                }
                state.error = ChatError(code: "send_failed", message: "That message didn't go through. Try again.")
                return .none
            }
        }
    }

    /// What's typed after `@` becomes `participant`'s name, and the draft is said to them.
    private func mention(_ participant: ParticipantSummary, in state: inout State) {
        if let typed = state.typedMention { state.draft.removeSubrange(typed.startIndex...) }
        state.draft += "@\(participant.name) "
        state.draftSelection = nil
        if !state.to.contains(participant) { state.to.append(participant) }
        state.marked = nil
    }

    /// The draft, sent to whoever was picked from `@`'s suggestions and whose name is still in it.
    private func send(_ state: inout State) -> Effect<Action> {
        guard state.canSend else { return .none }
        let text = state.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let to = state.to.filter { text.contains("@\($0.name)") }
            .map { ParticipantRef(kind: $0.kind, id: $0.id) }
        // The client-generated ID lets the conversation reject a duplicated delivery.
        let request = SendMessageRequest(id: MessageID(rawValue: uuid()), text: text, to: to)
        state.draft = ""
        state.draftSelection = nil
        state.to = []
        state.error = nil
        state.pending.append(request)
        return .run { send in
            do {
                try await chat.send(.message(request))
            } catch {
                await send(.sendFailed(request))
            }
        }
    }

    /// Whether `payload` takes one of your pending messages that mentions someone not in it yet.
    private static func bringsIn(_ payload: ChatEvent.Payload, in state: State) -> Bool {
        guard case .messageAccepted(_, _, let message) = payload,
            let request = state.pending.first(where: { $0.id == message.id })
        else { return false }
        let inIt = Set(state.participants.map(\.id))
        return request.to.contains { $0.kind == .person && !inIt.contains($0.id) }
    }

    /// The people in `space`, read for `session`'s person.
    private func loadSpacePeople(of space: SpaceSummary?, as session: Session?) -> Effect<Action> {
        guard let session, let space else { return .none }
        return .run { send in
            if let people = try? await server.people(session, space.id) { await send(.spacePeopleLoaded(people)) }
        }
    }

    /// Who's in the conversation `id`, read for `session`'s person.
    private func loadParticipants(of id: ConversationID, as session: Session?) -> Effect<Action> {
        guard let session else { return .none }
        return .run { send in
            if let participants = try? await server.participants(session, id) {
                await send(.participantsLoaded(participants))
            }
        }
    }

    private func apply(_ payload: ChatEvent.Payload, to state: inout State) {
        switch payload {
        case .ready(_, let botID, let status, let you):
            state.connection = .connected(botID: botID)
            state.you = you
            state.turn = status == .running ? Turn() : nil
        case .history(_, let messages):
            state.today = now
            state.messages = messages
            // Taken while the connection was away: it's said now.
            state.pending.removeAll { request in messages.contains { $0.id == request.id } }
        case .messageAccepted(_, _, let message):
            state.pending.removeAll { $0.id == message.id }
            append(message, to: &state)
        case .turnStarted(_, let turnID):
            state.turn = Turn()
            let message = state.messages.last { $0.role == .user }?.text ?? ""
            state.turns.updateOrAppend(TurnRecord(id: turnID, message: message, startedAt: now))
        case .turnPhase(_, _, let phase):
            state.turn = Turn(phase: phase, activity: state.turn?.activity, partial: state.turn?.partial)
        case .turnStatus(_, _, let activity):
            state.turn = Turn(phase: state.turn?.phase, activity: activity, partial: state.turn?.partial)
        case .turnPartial(_, _, let reply):
            state.turn = Turn(phase: .typing, activity: state.turn?.activity, partial: reply)
        case .turnCompleted(_, let turnID, let message):
            state.turn = nil
            append(message, to: &state)
            state.turns[id: turnID]?.outcome = .replied(message.text, at: now)
        case .turnFailed(_, let turnID, let error):
            state.turn = nil
            state.error = error
            if let turnID { state.turns[id: turnID]?.outcome = .failed(error.message, at: now) }
        case .turns(_, let turns):
            state.turns = IdentifiedArray(uniqueElements: turns)
        case .turnStep(_, let turnID, let step):
            state.turns[id: turnID]?.steps.append(step)
        case .accessRequested(_, let request):
            state.accessRequests.updateOrAppend(request)
        case .accessAnswered(_, let id, _):
            state.accessRequests.remove(id: id)
        case .notice(_, _, let error):
            state.error = error
        case .conversationJoined, .conversationSaid, .conversationTitled, .conversationLeft, .conversationDeleted,
            .memoryChanged, .reply:
            // Passed on to the window before this, or not the conversation's.
            break
        }
    }

    private func append(_ message: Message, to state: inout State) {
        guard !state.messages.contains(where: { $0.id == message.id }) else { return }
        state.today = now
        state.messages.append(message)
    }
}

/// A message, as the conversation shows it.
struct ShownMessage: Equatable, Identifiable {
    let id: MessageID
    let whose: Whose
    let text: String
    /// Who said it, when that's shown, and when: `Ann · 14:03`.
    let caption: String
    let delivery: Delivery
    /// The agent's turn that made it, when it's a reply of the agent's.
    let turn: TurnRecord?
    /// Its turn is shown beside it.
    let showsTurn: Bool
}

/// Whether a message is said, or still on its way.
enum Delivery: Equatable {
    case said
    /// Sent, but not yet taken by the conversation.
    case sending
}

/// What's under a conversation's messages: the composer, or why nothing new is said in it.
enum Writing: Equatable {
    case composer
    case closed(String)
}

/// Whose a message is, as it's drawn.
enum Whose: Equatable {
    case yours
    /// A person's other than you.
    case someoneElse
    case agent
}

/// A suggestion for the `@` being typed, as it's shown: whether Return picks it, and whether
/// mentioning them brings them into the conversation.
struct ShownSuggestion: Equatable, Identifiable {
    let participant: ParticipantSummary
    let isPicked: Bool
    let joins: Bool

    var id: String { participant.id }
}

extension MessageID {
    /// How its bubble leans, as the web works it out: the same for the same message.
    var lean: Lean { Lean(seed: rawValue.uuidString) }
}

extension TurnRecord {
    /// What it's shown under: the message it answered.
    var heading: String { message.isEmpty ? "Turn" : message }

    /// How many tools it called, and how it went: `2 calls · 4.2 s`.
    var summary: String {
        let steps = steps.filter { if case .toolCalled = $0.kind { true } else { false } }.count
        let calls = steps == 1 ? "1 call" : "\(steps) calls"
        switch outcome {
        case .running: return "\(calls) · running"
        case .replied(_, let at): return "\(calls) · \(duration(from: startedAt, to: at))"
        case .failed(_, let at): return "\(calls) · failed after \(duration(from: startedAt, to: at))"
        case .cancelled(let at): return "\(calls) · cancelled after \(duration(from: startedAt, to: at))"
        case .interrupted(let at): return "\(calls) · interrupted after \(duration(from: startedAt, to: at))"
        }
    }

    /// Why it failed, when it did.
    var failure: String? {
        if case .failed(let reason, _) = outcome { reason } else { nil }
    }
}

extension TurnStep {
    var title: String {
        switch kind {
        case .toolCalled(let name, _): name
        case .toolFinished(let name, _, let failure?): "\(name) failed (\(failure))"
        case .toolFinished(let name, _, nil): "\(name) answered"
        case .noticed: "Turgai told the model"
        }
    }

    /// What the tool was given, what it answered, or what the model was told.
    var detail: String {
        switch kind {
        case .toolCalled(_, let arguments): arguments
        case .toolFinished(_, let output, _): output
        case .noticed(let words): words
        }
    }

    /// The symbol it's shown with.
    var symbol: String {
        switch kind {
        case .toolCalled: "arrow.right.circle"
        case .toolFinished(_, _, .some): "exclamationmark.triangle"
        case .toolFinished(_, _, nil): "checkmark.circle"
        case .noticed: "info.circle"
        }
    }

    /// A tool it called failed.
    var failed: Bool {
        if case .toolFinished(_, _, .some) = kind { true } else { false }
    }

    /// How long after its turn started it happened: `+850 ms`.
    func offset(from start: Date) -> String {
        "+\(duration(from: start, to: at))"
    }
}

/// A short duration, such as `850 ms`, `4.2 s` or `3 min 5 s`.
private func duration(from start: Date, to end: Date) -> String {
    let seconds = max(end.timeIntervalSince(start), 0)
    if seconds < 1 { return "\(Int(seconds * 1000)) ms" }
    if seconds < 60 { return String(format: "%.1f s", seconds) }
    return "\(Int(seconds) / 60) min \(Int(seconds) % 60) s"
}

extension ChatEvent {
    /// The conversation it's about, when it's about one.
    var conversationID: ConversationID? {
        switch payload {
        case .ready(let id, _, _, _), .history(let id, _), .messageAccepted(let id, _, _), .turnStarted(let id, _),
            .turnPhase(let id, _, _), .turnStatus(let id, _, _), .turnPartial(let id, _, _),
            .turnCompleted(let id, _, _), .accessRequested(let id, _), .accessAnswered(let id, _, _),
            .turns(let id, _), .turnStep(let id, _, _), .conversationLeft(let id), .conversationDeleted(let id),
            .turnFailed(let id, _, _):
            id
        case .notice(let id, _, _):
            id
        case .reply, .memoryChanged:
            nil
        case .conversationJoined(let conversation), .conversationSaid(let conversation),
            .conversationTitled(let conversation):
            conversation.id
        }
    }
}
