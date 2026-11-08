import ComposableArchitecture
import SwiftUI

/// The signed-in person's profile, in a window of its own: their initial on a stamp of their
/// messages' yellow and their name; what's remembered about them, and Forget Everything…, which asks
/// again; Sign Out. It closes as they sign out.
struct ProfileView: View {
    @Bindable var store: StoreOf<ProfileFeature>
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
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
        .alert($store.scope(state: \.alert, action: \.alert))
        .onAppear { store.send(.shown) }
        .onChange(of: store.isSignedIn) { _, isSignedIn in
            if !isSignedIn { dismissWindow(id: WindowID.profile) }
        }
    }
}

/// Who they are: their initial on a stamp, and their name as the window's headline.
private struct ProfileHeading: View {
    let initial: String
    let name: String

    var body: some View {
        HStack(spacing: 16) {
            Text(initial)
                .font(.system(size: 26, weight: .heavy))
                .foregroundStyle(Color.inkOnSignal)
                .frame(width: 56, height: 56)
                .background(StampBackground(color: .bubbleYours, lean: Lean(degrees: 4)))
            Text(name)
                .font(.system(size: 30, weight: .heavy).width(.condensed))
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
    let shown: ProfileFeature.MemoryShown
    @Binding var remembers: Bool
    let canSwitch: Bool
    /// Why the switch didn't work, when it didn't.
    let problem: String?
    let canForget: Bool
    let forget: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Remembered about you")
                .font(.system(size: 15, weight: .bold))
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
    let line: ProfileFeature.MemoryLine

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(line.name)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(line.said == nil ? Color.turgaiInk : Color.turgaiMuted)
            if let said = line.said {
                Text(said)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.turgaiInk)
                    .textSelection(.enabled)
            }
        }
        .padding(.leading, CGFloat(line.depth) * 16)
    }
}

/// The profile's ground: the canvas, and a yellow block, theirs, cut off by the top right corner.
private struct ProfileField: View {
    var body: some View {
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
