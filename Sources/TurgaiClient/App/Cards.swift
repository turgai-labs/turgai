import ComposableArchitecture
import SwiftUI

/// The glass card for the screens before the chat: which server, waiting for it, and signing in.
package struct CardView: View {
    let card: AppFeature.Card
    let store: StoreOf<AppFeature>

    package init(card: AppFeature.Card, store: StoreOf<AppFeature>) {
        self.card = card
        self.store = store
    }

    package var body: some View {
        Group {
            switch card {
            case .address:
                AddressView(store: store)
                    .transition(.blurReplace)
            case .waiting(let waiting):
                WaitingView(waiting: waiting) { store.send($0) }
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

/// Which server to talk to, written once: the card's content, for an app with no server of its own.
private struct AddressView: View {
    @Bindable var store: StoreOf<AppFeature>

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Image.skylark
                .resizable()
                .scaledToFit()
                .frame(width: 56, height: 56)
                .foregroundStyle(Color.turgaiAccent)
            Text("Your Turgai")
                .font(.largeTitle.weight(.heavy))
                .foregroundStyle(Color.turgaiInk)
            Text("Where it answers: a Mac, a Pi, or a server of yours.")
                .font(.title3)
                .foregroundStyle(Color.turgaiMuted)
                .fixedSize(horizontal: false, vertical: true)
            if let notice = store.addressNotice {
                Text(notice)
                    .font(.callout)
                    .foregroundStyle(Color.turgaiAccent)
                    .fixedSize(horizontal: false, vertical: true)
            }
            TextField("turgai.local:3333", text: $store.address)
                .textContentType(.URL)
                .typedVerbatim()
                #if os(iOS)
                    .keyboardType(.URL)
                #endif
                .textFieldStyle(.roundedBorder)
                .controlSize(.large)
                .onSubmit { store.send(.addressSubmitted) }
            Button("Connect") { store.send(.addressSubmitted) }
                .buttonStyle(.glassProminent)
                .tint(.turgaiAccent)
                .controlSize(.large)
                .disabled(store.address.isEmpty)
        }
        .frame(maxWidth: 420, alignment: .leading)
    }
}

/// Signs in to the server, or creates a chat account there: the card's content.
private struct LoginView: View {
    @Bindable var store: StoreOf<AppFeature>

    private var form: AppFeature.LoginForm { store.login }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Image.skylark
                .resizable()
                .scaledToFit()
                .frame(width: 56, height: 56)
                .foregroundStyle(Color.turgaiAccent)
            Text(form.title)
                .font(.largeTitle.weight(.heavy))
                .foregroundStyle(Color.turgaiInk)
                .contentTransition(.opacity)
            if let notice = form.notice {
                Text(notice.text)
                    .font(.callout)
                    .foregroundStyle(Color.turgaiAccent)
                    .fixedSize(horizontal: false, vertical: true)
            }
            LoginFields(
                username: $store.login.username, password: $store.login.password,
                passwordAgain: $store.login.passwordAgain, mode: form.mode
            ) {
                store.send(.submitTapped)
            }
            LoginActions(
                title: form.title, switchPrompt: form.switchPrompt, isSubmitting: form.isSubmitting,
                isFilled: form.isFilled,
                submit: { store.send(.submitTapped) }, switchMode: { store.send(.modeChanged(form.otherMode)) })
        }
        .frame(maxWidth: 360, alignment: .leading)
        .animation(.smooth, value: form.mode)
    }
}

/// Shown until the chat is ready: a bold statement, and the next step; another server can be chosen
/// instead of one it was told the address of. The card's content.
private struct WaitingView: View {
    let waiting: AppFeature.Waiting
    let send: (AppFeature.Action) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Image.skylark
                .resizable()
                .scaledToFit()
                .frame(width: 56, height: 56)
                .foregroundStyle(Color.turgaiAccent)
            Text(waiting.title)
                .font(.largeTitle.weight(.heavy))
                .foregroundStyle(Color.turgaiInk)
                .contentTransition(.opacity)
            Text(waiting.message)
                .font(.title3)
                .foregroundStyle(Color.turgaiMuted)
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(.opacity)
            Group {
                switch waiting.connection {
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
            .transition(.blurReplace)
            if waiting.canChangeServer {
                Button("Change server") { send(.changeServerTapped) }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.signalBlue)
            }
        }
        .frame(maxWidth: 420, alignment: .leading)
    }
}

/// Turgai's geometry: a canvas with a large coral circle and a yellow bar, for
/// the glass to sit on.
package struct ColorField: View {
    package init() {}

    package var body: some View {
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
    @Binding var passwordAgain: String
    let mode: AppFeature.LoginForm.Mode
    let submit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Username", text: $username)
                .textContentType(.username)
                .typedVerbatim()
            SecureField("Password", text: $password)
                .textContentType(mode == .register ? .newPassword : .password)
            if mode == .register {
                SecureField("Password again", text: $passwordAgain)
                    .textContentType(.newPassword)
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
