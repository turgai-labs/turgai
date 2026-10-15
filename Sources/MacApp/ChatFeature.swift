import ComposableArchitecture
import Foundation
import TurgaiModels

/// One conversation over the chat socket: history, live turns, and sending.
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
        var partial: Message?
    }

    @ObservableState
    struct State: Equatable {
        var connection = Connection.connecting
        var messages: [Message] = []
        /// Sent, but not yet accepted by the conversation.
        var pending: [SendMessageRequest] = []
        var turn: Turn?
        /// Actions waiting for the user's consent, oldest first.
        var approvals: IdentifiedArrayOf<Approval> = []
        var draft = ""
        var error: ChatError?
        /// The agent's turns, step by step: the past ones, then each new one as it runs.
        var turns: IdentifiedArrayOf<TurnRecord> = []
    }

    enum Action: BindableAction {
        case binding(BindingAction<State>)
        case connect(Session)
        case disconnect
        case received(ChatEvent)
        case closed(why: String)
        case sendTapped
        case sendFailed(SendMessageRequest)
        case approvalAnswered(Approval.ID, ApprovalDecision)
    }

    private enum CancelID { case socket }

    @Dependency(\.chat) var chat
    @Dependency(\.continuousClock) var clock
    @Dependency(\.date.now) var now
    @Dependency(\.uuid) var uuid

    var body: some ReducerOf<Self> {
        BindingReducer()
        Reduce { state, action in
            switch action {
            case .binding:
                return .none

            case .connect(let session):
                state.connection = .connecting
                return .run { send in
                    let why: String
                    do {
                        for try await event in await chat.connect(session) {
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
                state.approvals = []
                return .none

            case .received(let event):
                apply(event.payload, to: &state)
                return .none

            case .sendTapped:
                let text = state.draft.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty, case .connected = state.connection else { return .none }
                // The client-generated ID lets the conversation reject a duplicated delivery.
                let request = SendMessageRequest(id: MessageID(rawValue: uuid()), text: text)
                state.draft = ""
                state.error = nil
                state.pending.append(request)
                return .run { send in
                    do {
                        try await chat.send(.message(request))
                    } catch {
                        await send(.sendFailed(request))
                    }
                }

            case .approvalAnswered(let id, let decision):
                guard state.approvals.remove(id: id) != nil else { return .none }
                return .run { _ in
                    // Unanswered, the request expires as a denial on the server.
                    try? await chat.send(.approval(id: id, decision: decision))
                }

            case .sendFailed(let request):
                state.pending.removeAll { $0.id == request.id }
                if state.draft.isEmpty { state.draft = request.text }
                state.error = ChatError(code: "send_failed", message: "That message didn't go through. Try again.")
                return .none
            }
        }
    }

    private func apply(_ payload: ChatEvent.Payload, to state: inout State) {
        switch payload {
        case .ready(_, let botID, let status):
            state.connection = .connected(botID: botID)
            state.turn = status == .running ? Turn() : nil
        case .history(_, let messages):
            state.messages = messages
        case .messageAccepted(_, _, let message):
            state.pending.removeAll { $0.id == message.id }
            append(message, to: &state)
        case .turnStarted(_, let turnID):
            state.turn = Turn()
            let message = state.messages.last { $0.role == .user }?.text ?? ""
            state.turns.updateOrAppend(TurnRecord(id: turnID.rawValue.uuidString, message: message, startedAt: now))
        case .turnPhase(_, _, let phase):
            state.turn = Turn(phase: phase, activity: state.turn?.activity, partial: state.turn?.partial)
        case .turnStatus(_, _, let activity):
            state.turn = Turn(phase: state.turn?.phase, activity: activity, partial: state.turn?.partial)
        case .turnPartial(_, _, let message):
            state.turn = Turn(phase: .typing, activity: state.turn?.activity, partial: message)
        case .turnCompleted(_, let turnID, let message):
            state.turn = nil
            append(message, to: &state)
            state.turns[id: turnID.rawValue.uuidString]?.outcome = .replied(message.text, at: now)
        case .turnFailed(_, let turnID, let error):
            state.turn = nil
            state.error = error
            if let turnID { state.turns[id: turnID.rawValue.uuidString]?.outcome = .failed(error.message, at: now) }
        case .turns(_, let turns):
            state.turns = IdentifiedArray(uniqueElements: turns)
        case .turnStep(_, let turnID, let step):
            state.turns[id: turnID.rawValue.uuidString]?.steps.append(step)
        case .approvalRequested(_, _, let approval):
            state.approvals.updateOrAppend(approval)
        case .approvalResolved(_, let id, _):
            state.approvals.remove(id: id)
        case .notice(_, _, let error):
            state.error = error
        }
    }

    private func append(_ message: Message, to state: inout State) {
        guard !state.messages.contains(where: { $0.id == message.id }) else { return }
        state.messages.append(message)
    }
}
