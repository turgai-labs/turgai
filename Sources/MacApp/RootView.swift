import ComposableArchitecture
import SwiftUI

struct RootView: View {
    @Bindable var store: StoreOf<AppFeature>
    /// The live objects, for the window's objects panel.
    let objects: ObjectsClient

    var body: some View {
        // One background, and one card on it whose content changes, so a new screen reshapes
        // the card instead of tearing it down and building another.
        ZStack {
            ColorField()
            switch screen {
            case .chat(let session):
                MainWindow(session: session, store: store, objects: objects)
                    .transition(.opacity)
            case .card(let card):
                self.card(card)
                    .transition(.opacity)
            }
        }
        .animation(.smooth, value: screen)
        .frame(minWidth: 640, minHeight: 480)
        .task { store.send(.appeared) }
    }

    /// What the window shows: the chat, or a card before it.
    private enum Screen: Equatable {
        case card(Card)
        case chat(Session)
    }

    private enum Card: Equatable {
        case waiting(AppFeature.Connection)
        case login
    }

    private var screen: Screen {
        switch (store.connection, store.account) {
        case (.ready, .signedIn(let session)): .chat(session)
        case (.ready, .signedOut): .card(.login)
        case (.ready, .unknown): .card(.waiting(.checking))
        case (let connection, _): .card(.waiting(connection))
        }
    }

    /// The glass card for the screens before the chat.
    private func card(_ card: Card) -> some View {
        Group {
            switch card {
            case .waiting(let connection):
                WaitingView(connection: connection) { store.send($0) }
                    .transition(.blurReplace)
            case .login:
                LoginView(store: store)
                    .transition(.blurReplace)
            }
        }
        .padding(40)
        .glassEffect(.regular, in: .rect(cornerRadius: 32))
    }
}

/// Signs in to the local server, or creates a chat account there: the card's content.
struct LoginView: View {
    @Bindable var store: StoreOf<AppFeature>

    private var form: AppFeature.LoginForm { store.login }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Image.skylark
                .resizable()
                .scaledToFit()
                .frame(width: 56, height: 56)
                .foregroundStyle(Color.turgaiAccent)
            Text(title)
                .font(.system(size: 40, weight: .heavy))
                .foregroundStyle(Color.turgaiInk)
                .contentTransition(.opacity)
            if let notice {
                Text(notice)
                    .font(.callout)
                    .foregroundStyle(Color.turgaiAccent)
                    .fixedSize(horizontal: false, vertical: true)
            }
            LoginFields(
                username: $store.login.username, password: $store.login.password, mode: form.mode
            ) {
                store.send(.submitTapped)
            }
            LoginActions(
                title: title, switchPrompt: switchPrompt, isSubmitting: form.progress == .submitting,
                isFilled: !form.username.isEmpty && !form.password.isEmpty,
                submit: { store.send(.submitTapped) }, switchMode: { store.send(.modeChanged(otherMode)) })
        }
        .frame(maxWidth: 360, alignment: .leading)
        .animation(.smooth, value: form.mode)
    }

    private var title: String {
        switch form.mode {
        case .signIn: "Sign in"
        case .register: "Create account"
        }
    }

    private var otherMode: AppFeature.LoginForm.Mode {
        switch form.mode {
        case .signIn: .register
        case .register: .signIn
        }
    }

    private var switchPrompt: String {
        switch form.mode {
        case .signIn: "Create an account"
        case .register: "I have an account"
        }
    }

    private var notice: String? {
        switch form.notice {
        case .sessionEnded: "Your session ended. Sign in again."
        case .invalidCredentials: "That username and password didn't match."
        case .invalidUsername: "Choose a username of 3 to 64 letters, numbers, dots, dashes, or underscores."
        case .weakPassword: "Choose a password with at least 12 characters."
        case .usernameUnavailable: "Turgai couldn't create that account. The username may be taken."
        case .unavailable(let reason): "Turgai didn't answer (\(reason)). Try again in a moment."
        case nil: nil
        }
    }
}

/// Shown until the chat is ready: a bold statement, and the next step. The card's content.
struct WaitingView: View {
    let connection: AppFeature.Connection
    let send: (AppFeature.Action) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Image.skylark
                .resizable()
                .scaledToFit()
                .frame(width: 56, height: 56)
                .foregroundStyle(Color.turgaiAccent)
            Text(title)
                .font(.system(size: 40, weight: .heavy))
                .foregroundStyle(Color.turgaiInk)
                .contentTransition(.opacity)
            Text(message)
                .font(.title3)
                .foregroundStyle(Color.turgaiMuted)
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(.opacity)
            nextStep
                .transition(.blurReplace)
        }
        .frame(maxWidth: 420, alignment: .leading)
    }

    private var title: String {
        switch connection {
        case .checking: "Looking for Turgai"
        case .unreachable: "Turgai is starting"
        case .setupPending, .ready: "Almost there"
        }
    }

    private var message: String {
        switch connection {
        case .checking: "One moment."
        case .unreachable: "I'll open the chat as soon as it answers. If it stopped, the menu bar says why."
        case .setupPending, .ready:
            "Finish setting up in your browser: an account, a model, and storage. I'll open the chat when you're done."
        }
    }

    @ViewBuilder
    private var nextStep: some View {
        switch connection {
        case .checking, .unreachable:
            ProgressView()
                .controlSize(.small)
        case .setupPending, .ready:
            Button("Open setup") { send(.openSetupTapped) }
                .buttonStyle(.glassProminent)
                .tint(.turgaiAccent)
                .controlSize(.large)
        }
    }
}

/// Turgai's geometry: a canvas with a large coral circle and a yellow bar, for
/// the glass to sit on.
struct ColorField: View {
    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack {
                Color.turgaiCanvas
                Circle()
                    .fill(Color.signalCoral)
                    .frame(width: size.height * 0.9)
                    .position(x: size.width * 0.82, y: size.height * 0.18)
                Rectangle()
                    .fill(Color.signalYellow)
                    .frame(width: size.width * 0.55, height: size.height * 0.16)
                    .rotationEffect(.degrees(-8))
                    .position(x: size.width * 0.22, y: size.height * 0.86)
            }
        }
        .ignoresSafeArea()
    }
}

/// The username and password, and what a new one needs. Typing changes only this.
private struct LoginFields: View {
    @Binding var username: String
    @Binding var password: String
    let mode: AppFeature.LoginForm.Mode
    let submit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Username", text: $username)
                .textContentType(.username)
            SecureField("Password", text: $password)
                .textContentType(mode == .register ? .newPassword : .password)
            if mode == .register {
                Text("Letters, numbers, dots, dashes, or underscores. A password of at least 12 characters.")
                    .font(.caption)
                    .foregroundStyle(Color.turgaiMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .textFieldStyle(.roundedBorder)
        .controlSize(.large)
        .onSubmit(submit)
    }
}

/// Signing in or creating the account, and switching between the two.
private struct LoginActions: View {
    let title: String
    let switchPrompt: String
    let isSubmitting: Bool
    /// Whether both a username and a password are typed.
    let isFilled: Bool
    let submit: () -> Void
    let switchMode: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            Button(action: submit) {
                if isSubmitting {
                    ProgressView().controlSize(.small)
                } else {
                    Text(title)
                }
            }
            .buttonStyle(.glassProminent)
            .tint(.turgaiAccent)
            .controlSize(.large)
            .disabled(isSubmitting || !isFilled)
            Button(switchPrompt, action: switchMode)
                .buttonStyle(.plain)
                .foregroundStyle(Color.signalBlue)
                .disabled(isSubmitting)
        }
    }
}
