import ComposableArchitecture
import SwiftUI

struct RootView: View {
    @Bindable var store: StoreOf<AppFeature>

    var body: some View {
        Group {
            switch (store.connection, store.account) {
            case (.ready, .signedIn(let session)):
                ChatView(session: session, store: store.scope(state: \.chat, action: \.chat))
            case (.ready, .signedOut):
                LoginView(store: store)
            case (.ready, .unknown):
                WaitingView(connection: .checking) { store.send($0) }
            case (let connection, _):
                WaitingView(connection: connection) { store.send($0) }
            }
        }
        .frame(minWidth: 640, minHeight: 480)
        .task { store.send(.appeared) }
    }
}

/// Signs in to the local server, or creates a chat account there.
struct LoginView: View {
    @Bindable var store: StoreOf<AppFeature>

    private var form: AppFeature.LoginForm { store.login }

    var body: some View {
        ZStack {
            ColorField()
            VStack(alignment: .leading, spacing: 20) {
                Image.skylark
                    .resizable()
                    .scaledToFit()
                    .frame(width: 56, height: 56)
                    .foregroundStyle(Color.turgaiAccent)
                Text(title)
                    .font(.system(size: 40, weight: .heavy))
                    .foregroundStyle(Color.turgaiInk)
                if let notice {
                    Text(notice)
                        .font(.callout)
                        .foregroundStyle(Color.turgaiAccent)
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: 12) {
                    TextField("Username", text: $store.login.username)
                        .textContentType(.username)
                    SecureField("Password", text: $store.login.password)
                        .textContentType(form.mode == .register ? .newPassword : .password)
                    if form.mode == .register {
                        Text("Letters, numbers, dots, dashes, or underscores. A password of at least 12 characters.")
                            .font(.caption)
                            .foregroundStyle(Color.turgaiMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .textFieldStyle(.roundedBorder)
                .controlSize(.large)
                .onSubmit { store.send(.submitTapped) }
                HStack(spacing: 16) {
                    Button {
                        store.send(.submitTapped)
                    } label: {
                        if form.progress == .submitting {
                            ProgressView().controlSize(.small)
                        } else {
                            Text(title)
                        }
                    }
                    .buttonStyle(.glassProminent)
                    .tint(.turgaiAccent)
                    .controlSize(.large)
                    .disabled(form.progress == .submitting || form.username.isEmpty || form.password.isEmpty)
                    Button(switchPrompt) { store.send(.modeChanged(otherMode)) }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.signalBlue)
                        .disabled(form.progress == .submitting)
                }
            }
            .frame(maxWidth: 360, alignment: .leading)
            .padding(40)
            .glassEffect(.regular, in: .rect(cornerRadius: 32))
        }
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

/// Shown until the chat is ready: a bold statement on a color field, and the next step.
struct WaitingView: View {
    let connection: AppFeature.Connection
    let send: (AppFeature.Action) -> Void

    var body: some View {
        ZStack {
            ColorField()
            VStack(alignment: .leading, spacing: 20) {
                Image.skylark
                    .resizable()
                    .scaledToFit()
                    .frame(width: 56, height: 56)
                    .foregroundStyle(Color.turgaiAccent)
                Text(title)
                    .font(.system(size: 40, weight: .heavy))
                    .foregroundStyle(Color.turgaiInk)
                Text(message)
                    .font(.title3)
                    .foregroundStyle(Color.turgaiMuted)
                    .fixedSize(horizontal: false, vertical: true)
                nextStep
            }
            .frame(maxWidth: 420, alignment: .leading)
            .padding(40)
            .glassEffect(.regular, in: .rect(cornerRadius: 32))
        }
        .animation(.smooth, value: connection)
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
