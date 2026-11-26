#if os(iOS)
    import ComposableArchitecture
    import SwiftUI
    import TurgaiClient

    /// What the app shows: before someone's signed in, Turgai's card on its field, as on a Mac; then
    /// their spaces.
    struct PhoneRoot: View {
        @Bindable var store: StoreOf<PhoneFeature>
        @Environment(\.scenePhase) private var scenePhase

        var body: some View {
            ZStack {
                switch store.app.screen {
                case .card(let card):
                    ColorField()
                    ScrollView {
                        CardView(card: card, store: store.scope(\.app, action: \.app))
                            .padding(20)
                            .frame(maxWidth: .infinity, minHeight: 600)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .transition(.opacity)
                case .chat(let session):
                    PhoneHome(session: session, store: store)
                        .transition(.opacity)
                }
            }
            .animation(.smooth, value: store.app.screen)
            .task { store.send(.app(.appeared)) }
            // Whether it's active, as the system says: the app decides what that changes.
            .onChange(of: scenePhase) { _, phase in store.send(.app(.scenePhaseChanged(phase))) }
        }
    }
#endif
