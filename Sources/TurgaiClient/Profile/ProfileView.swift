import ComposableArchitecture
import SwiftUI

/// The signed-in person's profile: their initial on a stamp of their messages' yellow and their
/// name; what's remembered about them, and Forget Everything…, which asks again; Sign Out. Whatever
/// shows it closes it as they sign out, by `signedOut`. While it's open, what's remembered stays
/// current.
package struct ProfileView: View {
    @Bindable package var store: StoreOf<ProfileFeature>
    /// They signed out: what shows it closes it.
    let signedOut: () -> Void

    package init(store: StoreOf<ProfileFeature>, signedOut: @escaping () -> Void) {
        self.store = store
        self.signedOut = signedOut
    }

    package var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            ProfileHeading(initial: store.initial, name: store.name)
            MemorySection(
                shown: store.memoryShown, remembers: $store.remembers.sending(\.rememberingToggled),
                canSwitch: store.canSwitchRemembering, problem: store.rememberingProblem, canForget: store.canForget
            ) { store.send(.forgetTapped) }
            Spacer(minLength: 0)
            Button("Sign Out") { store.send(.signOutTapped) }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(ProfileField())
        .alert($store.scope(\.$alert, action: \.alert))
        .onChange(of: store.isSignedIn) { _, isSignedIn in
            if !isSignedIn { signedOut() }
        }
    }
}

/// Who they are: their initial on a stamp, and their name as the window's headline.
private struct ProfileHeading: View {
    package let initial: String
    package let name: String

    package var body: some View {
        HStack(spacing: 16) {
            Text(initial)
                .font(.largeTitle.weight(.heavy))
                .foregroundStyle(Color.inkOnSignal)
                .frame(width: 56, height: 56)
                .background(StampBackground(color: .bubbleYours, lean: Lean(degrees: 4)))
            Text(name)
                .font(.largeTitle.weight(.heavy).width(.condensed))
                .tracking(-0.3)
                .lineLimit(1)
                .foregroundStyle(Color.turgaiInk)
        }
    }
}

/// What's remembered about them, a line for each name, under the names it's under; or why there's
/// nothing to show. Above it, the switch that has what they say remembered or not; Forget
/// Everything… under it, while there's something to forget.
private struct MemorySection: View {
    package let shown: ProfileFeature.MemoryShown
    @Binding package var remembers: Bool
    package let canSwitch: Bool
    /// Why the switch didn't work, when it didn't.
    package let problem: String?
    package let canForget: Bool
    package let forget: () -> Void

    package var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Remembered about you")
                .font(.title3.weight(.bold))
                .foregroundStyle(Color.turgaiInk)
            Toggle(isOn: $remembers) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Remember what I say")
                    Text("Off, nothing new is remembered. What is stays until you forget it.")
                        .font(.caption)
                        .foregroundStyle(Color.turgaiMuted)
                }
            }
            .toggleStyle(.switch)
            .disabled(!canSwitch)
            if let problem {
                Text(problem).font(.caption).foregroundStyle(Color.turgaiAccent)
            }
            switch shown {
            case .reading:
                ProgressView().controlSize(.small)
            case .lines(let lines):
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(lines) { (line: ProfileFeature.MemoryLine) in
                            MemoryLineView(line: line)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 320)
            case .note(let note):
                Text(note).foregroundStyle(Color.turgaiMuted)
            }
            Button("Forget Everything…", role: .destructive, action: forget)
                .disabled(!canForget)
        }
    }
}

/// A remembered name, set in by how far under the person it is: what was said for it after it,
/// or the name alone when it only groups the ones under it.
private struct MemoryLineView: View {
    package let line: ProfileFeature.MemoryLine

    package var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(line.name)
                .font(.body.weight(.semibold))
                .foregroundStyle(line.said == nil ? Color.turgaiInk : Color.turgaiMuted)
            if let said = line.said {
                Text(said)
                    .font(.body)
                    .foregroundStyle(Color.turgaiInk)
                    .textSelection(.enabled)
            }
        }
        .padding(.leading, CGFloat(line.depth) * 16)
    }
}

/// The profile's ground: the canvas, and a yellow block, theirs, cut off by the top right corner.
private struct ProfileField: View {
    package var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.turgaiCanvas
                Rectangle()
                    .fill(Color.signalYellow)
                    .frame(width: 220, height: 110)
                    .rotationEffect(.degrees(-9))
                    .position(x: geometry.size.width - 30, y: 10)
            }
        }
        .ignoresSafeArea()
    }
}
