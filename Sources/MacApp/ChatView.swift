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
    @Environment(\.openWindow) private var openWindow

    private var state: ChatFeature.State { store.state }

    var body: some View {
        ScrollViewReader { reader in
            ScrollView {
                MessageList(messages: state.messages, you: state.you, pending: state.pending, turn: state.turn)
            }
            // The messages run under the floating bars, softened at the edges.
            .safeAreaInset(edge: .top, spacing: 0) { header }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                BottomBar(error: state.error, draft: $store.draft, isConnected: isConnected) {
                    store.send(.sendTapped)
                }
            }
            .onChange(of: state.messages.last?.id) { scrollToEnd(reader) }
            .onChange(of: state.pending.last?.id) { scrollToEnd(reader) }
            .onChange(of: state.turn) { scrollToEnd(reader) }
        }
        .background(Color.turgaiCanvas)
        .ignoresSafeArea(.container, edges: .top)
        .modifier(
            AccessRequestAlert(request: state.accessRequests.first) { request, answer in
                store.send(.accessAnswered(request.id, answer))
            })
        .task(id: session) { store.send(.connect(session)) }
        .onDisappear { store.send(.disconnect) }
    }

    private var isConnected: Bool {
        if case .connected = state.connection { true } else { false }
    }

    /// A floating glass capsule: the mark, the name, and the connection. Clicking it opens
    /// the agent's turns.
    private var header: some View {
        Button {
            openWindow(id: WindowID.turns)
        } label: {
            headerLabel
        }
        .buttonStyle(.plain)
        .help("Show the agent's turns")
        .frame(maxWidth: .infinity)
        // Clear of the window's traffic lights under the hidden title bar.
        .padding(.top, 36)
        .padding(.bottom, 8)
    }

    private var headerLabel: some View {
        HStack(spacing: 10) {
            Image.skylark
                .resizable()
                .scaledToFit()
                .frame(width: 22, height: 22)
                .foregroundStyle(Color.turgaiAccent)
            Text(title)
                .font(.system(size: 18, weight: .heavy))
                .lineLimit(1)
                .foregroundStyle(Color.turgaiInk)
            Circle()
                .fill(connectionColor)
                .frame(width: 8, height: 8)
                .help(connectionHelp)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .glassEffect(.regular.interactive(), in: .capsule)
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
                .frame(maxWidth: .infinity, alignment: .leading)
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

private struct Composer: View {
    @Binding var draft: String
    let isConnected: Bool
    let send: () -> Void

    var body: some View {
        GlassEffectContainer(spacing: 12) {
            HStack(alignment: .bottom, spacing: 12) {
                TextField("Message Turgai", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...8)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .glassEffect(.regular, in: .rect(cornerRadius: 22))
                    .onSubmit(send)
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
}

/// The conversation: what was said, what's sent but not yet taken, and the turn running now.
private struct MessageList: View {
    let messages: [Message]
    /// The id of the person this app is.
    let you: String?
    let pending: [SendMessageRequest]
    let turn: ChatFeature.Turn?

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 12) {
            ForEach(messages) { (message: Message) in
                Bubble(
                    role: message.role, text: message.text,
                    someoneElse: message.author.flatMap { $0.kind == .person && $0.id != you ? $0.name : nil }
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
            Composer(draft: $draft, isConnected: isConnected, send: send)
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
