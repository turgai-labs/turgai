import ComposableArchitecture
import SwiftUI
import TurgaiClient

struct RootView: View {
    @Bindable var store: StoreOf<AppFeature>
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        // One background, and one card on it whose content changes, so a new screen reshapes
        // the card instead of tearing it down and building another.
        ZStack {
            ColorField()
            switch store.screen {
            case .chat(let session):
                MainWindow(session: session, store: store)
                    .transition(.opacity)
            case .card(let card):
                CardView(card: card, store: store)
                    .transition(.opacity)
            }
        }
        .animation(.smooth, value: store.screen)
        .frame(minWidth: 640, minHeight: 480)
        .task { store.send(.appeared) }
        // Whether it's active, as the system says: the app decides what that changes.
        .onChange(of: scenePhase) { _, phase in store.send(.scenePhaseChanged(phase)) }
    }
}
