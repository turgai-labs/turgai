import AppKit
import ComposableArchitecture
import SwiftUI
import TurgaiModels

/// The conversation with the default bot.
struct ChatView: View {
    let session: Session
    @Bindable var store: StoreOf<ChatFeature>

    private var state: ChatFeature.State { store.state }

    var body: some View {
        ScrollViewReader { reader in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(state.messages) { message in
                        Bubble(role: message.role, text: message.text)
                            .id(message.id)
                    }
                    ForEach(state.pending) { request in
                        Bubble(role: .user, text: request.text)
                            .opacity(0.55)
                            .id(request.id)
                    }
                    if let turn = state.turn {
                        TurnView(turn: turn)
                            .id("turn")
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
            }
            // The messages run under the floating bars, softened at the edges.
            .safeAreaInset(edge: .top, spacing: 0) { header }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    if let error = state.error {
                        Text(error.message)
                            .font(.callout)
                            .foregroundStyle(Color.turgaiAccent)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .glassEffect(.regular, in: .capsule)
                    }
                    Composer(draft: $store.draft, isConnected: isConnected) { store.send(.sendTapped) }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 20)
            }
            .onChange(of: state.messages.last?.id) { scrollToEnd(reader) }
            .onChange(of: state.pending.last?.id) { scrollToEnd(reader) }
            .onChange(of: state.turn) { scrollToEnd(reader) }
        }
        .background(Color.turgaiCanvas)
        .ignoresSafeArea(.container, edges: .top)
        .alert(
            approvalTitle,
            isPresented: Binding(get: { state.approvals.first != nil }, set: { _ in }),
            presenting: state.approvals.first
        ) { approval in
            Button("Don't Allow", role: .cancel) { store.send(.approvalAnswered(approval.id, .denied)) }
            Button("Allow") { store.send(.approvalAnswered(approval.id, .granted)) }
        } message: { approval in
            Text(approval.arguments)
        }
        // A menu bar app sits behind other apps; come forward to ask.
        .onChange(of: state.approvals.first?.id) { _, id in
            if id != nil { NSApplication.shared.activate() }
        }
        .task(id: session) { store.send(.connect(session)) }
        .onDisappear { store.send(.disconnect) }
    }

    private var approvalTitle: String {
        state.approvals.first.map { "Allow Turgai to use \($0.action)?" } ?? ""
    }

    private var isConnected: Bool {
        if case .connected = state.connection { true } else { false }
    }

    /// A floating glass capsule: the mark, the name, and the connection.
    private var header: some View {
        HStack(spacing: 10) {
            Image.skylark
                .resizable()
                .scaledToFit()
                .frame(width: 22, height: 22)
                .foregroundStyle(Color.turgaiAccent)
            Text("Turgai")
                .font(.system(size: 18, weight: .heavy))
                .foregroundStyle(Color.turgaiInk)
            Circle()
                .fill(connectionColor)
                .frame(width: 8, height: 8)
                .help(connectionHelp)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .capsule)
        .frame(maxWidth: .infinity)
        // Clear of the window's traffic lights under the hidden title bar.
        .padding(.top, 36)
        .padding(.bottom, 8)
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
        case .disconnected: "Reconnecting…"
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

/// A message: the user's on the right in coral, the bot's on the left in glass.
private struct Bubble: View {
    let role: MessageRole
    let text: String

    var body: some View {
        switch role {
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
