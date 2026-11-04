import AppKit
import ComposableArchitecture
import SwiftUI
import TurgaiModels

/// The open conversation.
struct ChatView: View {
    let session: Session
    /// What it's called.
    let title: String
    @Bindable var store: StoreOf<ChatFeature>

    private var state: ChatFeature.State { store.state }

    var body: some View {
        ScrollViewReader { reader in
            ScrollView {
                MessageList(
                    messages: state.messages, you: state.you, turns: state.turns, pending: state.pending,
                    turn: state.turn)
            }
            // The messages run under the floating composer, softened at the edge.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                BottomBar(
                    error: state.error, draft: $store.draft, isConnected: isConnected,
                    suggestions: state.suggestions, mention: { store.send(.mentioned($0)) }
                ) {
                    store.send(.sendTapped)
                }
            }
            .onChange(of: state.messages.last?.id) { scrollToEnd(reader) }
            .onChange(of: state.pending.last?.id) { scrollToEnd(reader) }
            .onChange(of: state.turn) { scrollToEnd(reader) }
        }
        .background(Color.turgaiCanvas)
        .toolbar {
            ToolbarItem(placement: .principal) { header }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    store.send(.addPeopleTapped)
                } label: {
                    Label("Add someone", systemImage: "person.badge.plus")
                }
                .help("Add someone from this space")
            }
        }
        .modifier(
            AccessRequestAlert(request: state.accessRequests.first) { request, answer in
                store.send(.accessAnswered(request.id, answer))
            })
        .task(id: session) { store.send(.connect(session)) }
        .onDisappear { store.send(.disconnect) }
        .sheet(
            isPresented: Binding(get: { state.addable != nil }, set: { if !$0 { store.send(.addingDismissed) } })
        ) {
            AddPeopleSheet(people: state.addable ?? [], add: { store.send(.addTapped($0)) }) {
                store.send(.addingDismissed)
            }
        }
    }

    private var isConnected: Bool {
        if case .connected = state.connection { true } else { false }
    }

    /// The toolbar's middle: the mark, the name, and the connection; under them, who's in the
    /// conversation.
    private var header: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image.skylark
                    .resizable()
                    .scaledToFit()
                    .frame(width: 14, height: 14)
                    .foregroundStyle(Color.turgaiAccent)
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                    .foregroundStyle(Color.turgaiInk)
                Circle()
                    .fill(connectionColor)
                    .frame(width: 6, height: 6)
                    .help(connectionHelp)
            }
            Text(state.participants.map(\.name).joined(separator: ", "))
                .font(.caption)
                .foregroundStyle(Color.turgaiMuted)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
    }

    private var connectionColor: Color {
        switch state.connection {
        case .connected: .signalBlue
        case .connecting: .signalYellow
        case .disconnected: .signalCoral
        }
    }

    private var connectionHelp: String {
        switch state.connection {
        case .connected: "Connected"
        case .connecting: "Connecting…"
        case .disconnected(let why): "Reconnecting… \(why)"
        }
    }

    private func scrollToEnd(_ reader: ScrollViewProxy) {
        withAnimation(.smooth) {
            if state.turn != nil {
                reader.scrollTo("turn", anchor: .bottom)
            } else if let last = state.pending.last {
                reader.scrollTo(last.id, anchor: .bottom)
            } else if let last = state.messages.last {
                reader.scrollTo(last.id, anchor: .bottom)
            }
        }
    }
}

/// A message: the user's own on the right in coral, someone else's on the left with their name,
/// the bot's on the left in glass.
private struct Bubble: View {
    let role: MessageRole
    let text: String
    /// Who wrote it, when that's someone else.
    var someoneElse: String? = nil

    var body: some View {
        switch role {
        case .user where someoneElse != nil:
            VStack(alignment: .leading, spacing: 4) {
                Text(someoneElse ?? "").font(.caption.weight(.semibold)).foregroundStyle(Color.turgaiMuted)
                Text(text)
                    .textSelection(.enabled)
                    .foregroundStyle(Color.turgaiInk)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .glassEffect(.regular, in: .rect(cornerRadius: 18))
            }
            .frame(maxWidth: 520, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        case .user:
            Text(text)
                .textSelection(.enabled)
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color.turgaiAccent, in: .rect(cornerRadius: 18))
                .frame(maxWidth: 520, alignment: .trailing)
                .frame(maxWidth: .infinity, alignment: .trailing)
        case .assistant:
            Text(Self.markdown(text))
                .textSelection(.enabled)
                .foregroundStyle(Color.turgaiInk)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .glassEffect(.regular, in: .rect(cornerRadius: 18))
                .frame(maxWidth: 560, alignment: .leading)
        }
    }

    private static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
    }
}

/// The reply being typed, or what the bot is doing before it types.
private struct TurnView: View {
    let turn: ChatFeature.Turn

    var body: some View {
        if let partial = turn.partial {
            Bubble(role: .assistant, text: partial.text)
        } else {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(turn.activity ?? (turn.phase == .typing ? "Typing…" : "Thinking…"))
                    .font(.callout)
                    .foregroundStyle(Color.turgaiMuted)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .glassEffect(.regular, in: .capsule)
        }
    }
}

/// The message field and its send button; above them, while an `@` is typed, who it could be.
private struct Composer: View {
    @Binding var draft: String
    let isConnected: Bool
    /// Who the `@` being typed could be.
    let suggestions: [ParticipantSummary]
    let mention: (ParticipantSummary) -> Void
    let send: () -> Void
    /// The suggestion Return or Tab picks, moved by ↑ and ↓.
    @State private var highlighted = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !suggestions.isEmpty {
                Suggestions(suggestions: suggestions, highlighted: highlighted, pick: mention)
            }
            field
        }
        .onChange(of: suggestions) { highlighted = 0 }
    }

    private var field: some View {
        GlassEffectContainer(spacing: 12) {
            HStack(alignment: .bottom, spacing: 12) {
                TextField("Message Turgai", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...8)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .glassEffect(.regular, in: .rect(cornerRadius: 22))
                    .onSubmit {
                        if let picked { mention(picked) } else { send() }
                    }
                    .onKeyPress(.downArrow) { move(by: 1) }
                    .onKeyPress(.upArrow) { move(by: -1) }
                    .onKeyPress(.tab) {
                        guard let picked else { return .ignored }
                        mention(picked)
                        return .handled
                    }
                Button(action: send) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 16, weight: .bold))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.circle)
                .tint(.turgaiAccent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!isConnected || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    /// The suggestion Return or Tab would pick: none when there are none.
    private var picked: ParticipantSummary? {
        suggestions.isEmpty ? nil : suggestions[min(highlighted, suggestions.count - 1)]
    }

    private func move(by step: Int) -> KeyPress.Result {
        guard !suggestions.isEmpty else { return .ignored }
        highlighted = (highlighted + step + suggestions.count) % suggestions.count
        return .handled
    }
}

/// Who the `@` being typed could be, the one Return picks marked: a click picks any.
private struct Suggestions: View {
    let suggestions: [ParticipantSummary]
    let highlighted: Int
    let pick: (ParticipantSummary) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, participant in
                Button {
                    pick(participant)
                } label: {
                    HStack(spacing: 8) {
                        icon(of: participant)
                            .frame(width: 16, height: 16)
                            .foregroundStyle(Color.turgaiAccent)
                        Text(participant.name).foregroundStyle(Color.turgaiInk)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        index == highlighted ? Color.turgaiAccent.opacity(0.15) : .clear, in: .rect(cornerRadius: 10)
                    )
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(6)
        .frame(maxWidth: 280)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
    }

    @ViewBuilder
    private func icon(of participant: ParticipantSummary) -> some View {
        switch participant.kind {
        case .agent: Image.skylark.resizable().scaledToFit()
        case .person: Image(systemName: "person.fill")
        }
    }
}

/// The conversation: what was said, what's sent but not yet taken, and the turn running now.
private struct MessageList: View {
    let messages: [Message]
    /// The id of the person this app is.
    let you: String?
    /// The agent's turns: a reply's is the one with its id.
    let turns: IdentifiedArrayOf<TurnRecord>
    let pending: [SendMessageRequest]
    let turn: ChatFeature.Turn?

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 12) {
            ForEach(messages) { (message: Message) in
                MessageRow(
                    message: message,
                    someoneElse: message.author.flatMap { $0.kind == .person && $0.id != you ? $0.name : nil },
                    turn: message.role == .assistant ? turns[id: TurnID(rawValue: message.id.rawValue)] : nil
                )
                .id(message.id)
            }
            ForEach(pending) { (request: SendMessageRequest) in
                Bubble(role: .user, text: request.text).opacity(0.55).id(request.id)
            }
            if let turn {
                TurnView(turn: turn).id("turn")
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
    }
}

/// The composer, and what went wrong above it if something did. Typing changes only this.
private struct BottomBar: View {
    let error: ChatError?
    @Binding var draft: String
    let isConnected: Bool
    let suggestions: [ParticipantSummary]
    let mention: (ParticipantSummary) -> Void
    let send: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error {
                Text(error.message)
                    .font(.callout)
                    .foregroundStyle(Color.turgaiAccent)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .glassEffect(.regular, in: .capsule)
            }
            Composer(draft: $draft, isConnected: isConnected, suggestions: suggestions, mention: mention, send: send)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 20)
    }
}

/// Asks about the oldest access request waiting for an answer, bringing the app forward to ask: a
/// menu bar app sits behind the others. Only an admin's answer counts.
private struct AccessRequestAlert: ViewModifier {
    let request: AccessRequest?
    let answer: (AccessRequest, AccessAnswer) -> Void

    func body(content: Content) -> some View {
        content
            .alert("Allow this?", isPresented: .constant(request != nil), presenting: request) {
                (request: AccessRequest) in
                Button("No", role: .cancel) { answer(request, .no) }
                Button("Once") { answer(request, .once) }
                Button("Always") { answer(request, .always) }
                Button("Everyone") { answer(request, .everyone) }
            } message: { (request: AccessRequest) in
                Text(request.request)
            }
            .onChange(of: request?.id) { _, id in
                if id != nil { NSApplication.shared.activate() }
            }
    }
}

/// The people in the conversation's space who aren't in it: picking one adds them.
private struct AddPeopleSheet: View {
    let people: [SpacePerson]
    let add: (SpacePerson) -> Void
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add someone").font(.headline)
            if people.isEmpty {
                Text("Everyone in this space is in this conversation.")
                    .foregroundStyle(Color.turgaiMuted)
            } else {
                List(people) { (person: SpacePerson) in
                    Button(person.name) { add(person) }.buttonStyle(.plain)
                }
                .frame(minHeight: 160)
            }
            HStack {
                Spacer()
                Button("Done", action: done).keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 320)
    }
}

/// A message, and for a reply of the agent's, ⓘ beside it that shows the turn that made it.
private struct MessageRow: View {
    let message: Message
    let someoneElse: String?
    let turn: TurnRecord?
    @State private var showsTurn = false

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            Bubble(role: message.role, text: message.text, someoneElse: someoneElse)
            if let turn {
                Button {
                    showsTurn = true
                } label: {
                    Image(systemName: "info.circle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.turgaiMuted)
                .help("What the agent did for this")
                .popover(isPresented: $showsTurn, arrowEdge: .trailing) { TurnStepsView(turn: turn) }
            }
        }
        .frame(maxWidth: .infinity, alignment: message.role == .assistant ? .leading : .trailing)
    }
}
