import ComposableArchitecture
import SwiftUI
import TurgaiModels

#if os(macOS)
    import AppKit
#endif

/// The open conversation, its name in the window's toolbar.
package struct ChatView: View {
    /// What it's called.
    let title: String
    @Bindable var store: StoreOf<ChatFeature>

    package init(title: String, store: StoreOf<ChatFeature>) {
        self.title = title
        self.store = store
    }

    package var body: some View {
        ScrollView {
            MessageList(store: store)
        }
        // What's new keeps the end in view, and a short conversation sits at the bottom.
        .defaultScrollAnchor(.bottom)
        // Scrolling back puts the keyboard away, following the finger.
        .scrollDismissesKeyboard(.interactively)
        // The messages run under the floating composer.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            BottomBar(store: store)
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                ConversationHeader(title: title, participants: store.participantsLine, notice: store.connectionNotice)
            }
        }
        .modifier(
            AccessRequestAlert(request: store.accessRequests.first) { request, answer in
                store.send(.accessAnswered(request.id, answer))
            })
    }
}

/// The toolbar's middle: the conversation's name, and what's wrong with the connection while
/// something is; under them, who's in it.
private struct ConversationHeader: View {
    let title: String
    let participants: String
    /// What's wrong with the connection: none while it's connected.
    let notice: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.headline)
                    .tracking(-0.3)
                    .lineLimit(1)
                    .foregroundStyle(Color.turgaiInk)
                if let notice {
                    Text(notice).font(.caption).foregroundStyle(Color.turgaiAccent)
                }
            }
            Text(participants)
                .font(.caption)
                .foregroundStyle(Color.turgaiMuted)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
    }
}

/// A message, as the web stamps them: yours on the right in yellow, the agent's on the left in blue,
/// someone else's on the left in coral; over it, its caption; faded while it's on its way. Its background leans
/// by `lean`; its text doesn't. What's `beside` it sits just after its end on a Mac; on a phone, where
/// its end can be the screen's, just after its caption.
private struct Bubble<Beside: View>: View {
    let whose: Whose
    let text: String
    let lean: Lean
    let caption: String
    let delivery: Delivery
    @ViewBuilder var beside: Beside

    var body: some View {
        VStack(alignment: whose == .yours ? .trailing : .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(Color.turgaiMuted)
                #if os(iOS)
                    beside
                #endif
            }
            .padding(.horizontal, 4)
            switch whose {
            case .someoneElse:
                Text(text)
                    .textSelection(.enabled)
                    .modifier(Stamp(color: .bubbleSomeoneElse, ink: .inkOnSignal, lean: lean))
                    .frame(maxWidth: 520, alignment: .leading)
            case .yours:
                Text(text)
                    .textSelection(.enabled)
                    .modifier(Stamp(color: .bubbleYours, ink: .inkOnSignal, lean: lean))
                    .frame(maxWidth: 520, alignment: .trailing)
            case .agent:
                Text(Self.markdown(text))
                    .textSelection(.enabled)
                    .modifier(Stamp(color: .bubbleAgent, ink: .white, lean: lean))
                    .overlay(alignment: .bottomTrailing) {
                        #if os(macOS)
                            beside.alignmentGuide(.trailing) { $0[.leading] - 8 }
                        #endif
                    }
                    .frame(maxWidth: 560, alignment: .leading)
            }
        }
        .opacity(delivery == .sending ? 0.55 : 1)
        .frame(maxWidth: .infinity, alignment: whose == .yours ? .trailing : .leading)
    }

    private static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
    }
}

/// A bubble's look: `ink` on a stamp of `color` leaning by `lean`.
private struct Stamp: ViewModifier {
    let color: Color
    let ink: Color
    let lean: Lean

    func body(content: Content) -> some View {
        content
            .foregroundStyle(ink)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(StampBackground(color: color, lean: lean))
    }
}

/// What the bot is doing before it types.
private struct Working: View {
    let activity: String

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(activity)
                .font(.callout)
                .foregroundStyle(Color.turgaiMuted)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: .capsule)
    }
}

/// The message field and its send button; above them, while an `@` is typed, who it could be.
private struct Composer: View {
    @Bindable var store: StoreOf<ChatFeature>

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !store.shownSuggestions.isEmpty {
                Suggestions(suggestions: store.shownSuggestions) { store.send(.mentioned($0)) }
            }
            HStack(alignment: .bottom, spacing: 12) {
                TextField(
                    "Message · @ to mention", text: $store.draft, selection: $store.draftSelection, axis: .vertical
                )
                .textFieldStyle(.plain)
                .lineLimit(1...8)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .glassEffect(.regular, in: .rect(cornerRadius: 22))
                // Return sends; Shift-Return starts a new line.
                .onSubmit { store.send(.submitted) }
                .onKeyPress(.return, phases: .down) { returnKey($0) }
                // The keys are the suggestions' while there are some, the field's otherwise.
                .onKeyPress(.downArrow) { suggestionsKey(.markMoved(by: 1)) }
                .onKeyPress(.upArrow) { suggestionsKey(.markMoved(by: -1)) }
                .onKeyPress(.tab) { suggestionsKey(.submitted) }
                switch store.composerButton {
                case .stop:
                    Button {
                        store.send(.stopTapped)
                    } label: {
                        Image(systemName: "stop.fill").font(.title3.weight(.bold))
                    }
                    .buttonStyle(SendStampStyle())
                    .keyboardShortcut(.cancelAction)
                    .help("Stop the reply")
                case .send:
                    Button {
                        store.send(.sendTapped)
                    } label: {
                        Image(systemName: "arrow.up").font(.title3.weight(.bold))
                    }
                    .buttonStyle(SendStampStyle())
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!store.canSend)
                }
            }
        }
    }

    /// Return with Shift held: a new line; without it, the field submits.
    private func returnKey(_ press: KeyPress) -> KeyPress.Result {
        guard press.modifiers.contains(.shift) else { return .ignored }
        store.send(.newLineTyped)
        return .handled
    }

    private func suggestionsKey(_ action: ChatFeature.Action) -> KeyPress.Result {
        guard store.picked != nil else { return .ignored }
        store.send(action)
        return .handled
    }
}

/// Send, on a coral stamp; on a quiet one while there's nothing to send.
private struct SendStampStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isEnabled ? Color.white : Color.turgaiMuted)
            .frame(width: 40, height: 40)
            .background(
                StampBackground(
                    color: isEnabled ? .turgaiAccent : Color.turgaiInk.opacity(0.1), lean: Lean(degrees: -3))
            )
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .contentShape(.rect)
    }
}

/// Who the `@` being typed could be, the one Return picks marked, and who'd join the conversation
/// by it: a click picks any.
private struct Suggestions: View {
    let suggestions: [ShownSuggestion]
    let pick: (ParticipantSummary) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(suggestions) { (suggestion: ShownSuggestion) in
                Button {
                    pick(suggestion.participant)
                } label: {
                    HStack(spacing: 8) {
                        ParticipantIcon(kind: suggestion.participant.kind)
                        Text(suggestion.participant.name).foregroundStyle(Color.turgaiInk)
                        if suggestion.joins {
                            Text("joins").font(.caption).foregroundStyle(Color.turgaiMuted)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        suggestion.isPicked ? Color.turgaiAccent.opacity(0.15) : .clear, in: .rect(cornerRadius: 10)
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
}

/// The skylark for an agent, a figure for a person.
private struct ParticipantIcon: View {
    let kind: ParticipantSummary.Kind

    var body: some View {
        Group {
            switch kind {
            case .agent: Image.skylark.resizable().scaledToFit()
            case .person: Image(systemName: "person.fill")
            }
        }
        .frame(width: 16, height: 16)
        .foregroundStyle(Color.turgaiAccent)
    }
}

/// The conversation: what was said, the reply being typed, what's sent but not yet taken, and what
/// the agent is doing before it types. Each part reads only its own: a word typed redraws only the
/// reply it's in.
private struct MessageList: View {
    let store: StoreOf<ChatFeature>

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 14) {
            SaidRows(store: store)
            TypingRow(store: store)
            SendingRows(store: store)
            WorkingRow(store: store)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
    }
}

/// What was said: read alone, so nothing typed redraws it.
private struct SaidRows: View {
    let store: StoreOf<ChatFeature>

    var body: some View {
        ForEach(store.said) { (shown: ShownMessage) in
            MessageRow(shown: shown, store: store).id(shown.id)
        }
    }
}

/// The reply being typed, while it is.
private struct TypingRow: View {
    let store: StoreOf<ChatFeature>

    var body: some View {
        if let typing = store.typing {
            MessageRow(shown: typing, store: store).id(typing.id)
        }
    }
}

/// What you've sent that isn't taken yet.
private struct SendingRows: View {
    let store: StoreOf<ChatFeature>

    var body: some View {
        ForEach(store.sending) { (shown: ShownMessage) in
            MessageRow(shown: shown, store: store).id(shown.id)
        }
    }
}

/// What the agent is doing before it types, while it is.
private struct WorkingRow: View {
    let store: StoreOf<ChatFeature>

    var body: some View {
        if let working = store.working {
            Working(activity: working)
        }
    }
}

/// The composer, and what went wrong above it if something did; or, where nothing new is said,
/// why. Typing changes only this.
private struct BottomBar: View {
    let store: StoreOf<ChatFeature>

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = store.error {
                Text(error.message)
                    .font(.callout)
                    .foregroundStyle(Color.turgaiAccent)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .glassEffect(.regular, in: .capsule)
            }
            switch store.writing {
            case .composer:
                Composer(store: store)
            case .closed(let why):
                Text(why)
                    .font(.callout)
                    .foregroundStyle(Color.turgaiMuted)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity)
                    .glassEffect(.regular, in: .rect(cornerRadius: 22))
            }
        }
        // Glass floats as far from the window's edges as the panel and the headline do; the
        // messages keep wider margins.
        .padding([.horizontal, .bottom], 10)
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
                // On a Mac, a question waiting for an answer brings the app forward.
                #if os(macOS)
                    if id != nil { NSApplication.shared.activate() }
                #endif
            }
    }
}

/// A message, and for a reply of the agent's, ⓘ just after it that shows the turn that made it:
/// one view, stamping in as it comes. It reads nothing of the store's, only sends to it, so a row
/// whose message is the same isn't drawn again.
private struct MessageRow: View {
    let shown: ShownMessage
    let store: StoreOf<ChatFeature>

    var body: some View {
        Bubble(
            whose: shown.whose, text: shown.text, lean: shown.id.lean, caption: shown.caption,
            delivery: shown.delivery
        ) {
            if shown.hasTurn {
                Button {
                    store.send(.turnTapped(shown.id))
                } label: {
                    Image(systemName: "info.circle")
                        // A finger's worth to press, around the glyph, taking no more room.
                        .padding(12)
                        .contentShape(.rect)
                        .padding(-12)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.turgaiMuted)
                .help("What the agent did for this")
                // Only closing it changes it from here.
                .popover(
                    isPresented: Binding(get: { shown.showsTurn }, set: { _ in store.send(.turnDismissed) }),
                    arrowEdge: .trailing
                ) {
                    TurnPopover(store: store)
                }
            }
        }
        .transition(.scale(scale: 0.78).combined(with: .opacity))
    }
}

/// The open turn's steps, as they're read: a moment while they are, then them, or why they
/// couldn't be.
private struct TurnPopover: View {
    let store: StoreOf<ChatFeature>

    var body: some View {
        switch store.openTurn?.steps {
        case .read(let turn)?:
            TurnStepsView(turn: turn)
        case .failed(let why)?:
            Text(why).foregroundStyle(Color.turgaiAccent).padding()
        case .reading?, nil:
            ProgressView().padding()
        }
    }
}
