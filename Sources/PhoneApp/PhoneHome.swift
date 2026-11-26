#if os(iOS)
    import ComposableArchitecture
    import SwiftUI
    import TurgaiClient
    import TurgaiModels

    /// Someone's spaces, as on a Mac: the spaces with the shown one's pages and conversations in the
    /// sidebar, and beside them what's open. Where the two don't fit side by side, what's opened
    /// comes over the sidebar, and goes back.
    struct PhoneHome: View {
        let session: Session
        @Bindable var store: StoreOf<PhoneFeature>
        /// The window's width: read here, outside the split view, whose sidebar is narrow even on an
        /// iPad.
        @Environment(\.horizontalSizeClass) private var width

        var body: some View {
            NavigationSplitView(preferredCompactColumn: shown) {
                // The spaces along the foot, in reach of a thumb, where the window is narrow; down
                // the side where there's room, as on a Mac.
                SpacesSide(store: store, rail: width == .compact ? .horizontal : .vertical)
            } detail: {
                OpenSide(store: store)
                    // The space's field, as the split view's own ground: it runs behind both sides,
                    // as behind a Mac's whole window.
                    .containerBackground(for: .navigationSplitView) {
                        WorkingField(hue: store.app.sidebar.shownSpaceHue)
                    }
            }
            .modifier(SidebarDialogs(store: store.scope(\.app.sidebar, action: \.app.sidebar)))
            .sheet(isPresented: Binding(get: { store.accountShown }, set: { if !$0 { store.send(.accountClosed) } })) {
                ProfileView(store: store.scope(\.app.profile, action: \.app.profile)) {
                    store.send(.accountClosed)
                }
            }
        }

        /// Where the two don't fit side by side: what's open over the sidebar, once something's
        /// opened.
        private var shown: Binding<NavigationSplitViewColumn> {
            Binding(
                get: { store.showsOpen ? .detail : .sidebar },
                set: { if $0 == .sidebar { store.send(.openClosed) } })
        }
    }

    /// The spaces, as a Mac's panel, as tall as the screen: each opens beside them; and the account,
    /// at the rail's end.
    private struct SpacesSide: View {
        let store: StoreOf<PhoneFeature>
        let rail: Axis

        var body: some View {
            SpacesPanel(
                store: store.scope(\.app.sidebar, action: \.app.sidebar),
                pages: store.scope(\.app.pages, action: \.app.pages), rail: rail,
                openConversation: { store.send(.conversationTapped($0)) },
                openPage: { store.send(.pageTapped($0)) }
            ) {
                AccountButton(initial: store.app.profile.initial) { store.send(.accountTapped) }
            }
            // A ground of its own, apart from what's open, its cards standing out on it: light, and the
            // space's field showing through.
            .containerBackground(.ultraThinMaterial, for: .navigation)
        }
    }

    /// What's open: the page opened from the spaces, or else the open conversation.
    private struct OpenSide: View {
        let store: StoreOf<PhoneFeature>

        var body: some View {
            Group {
                if let page = store.scope(\.app.openPage, action: \.app.openPage) {
                    PageContentView(content: page.content) { page.send(.pressed($0)) }
                        .navigationTitle(page.address.page.rawValue)
                } else {
                    ChatView(title: store.app.sidebar.openTitle, store: store.scope(\.app.chat, action: \.app.chat))
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .containerBackground(.clear, for: .navigation)
        }
    }

    /// The account, as the Mac's: the person's initial on a stamp of their messages' yellow.
    private struct AccountButton: View {
        let initial: String
        let open: () -> Void

        var body: some View {
            Button(action: open) {
                Text(initial)
                    .font(.headline.weight(.heavy))
                    .foregroundStyle(Color.inkOnSignal)
                    .frame(width: 32, height: 32)
                    .background(StampBackground(color: .bubbleYours, lean: Lean(degrees: 4)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Account")
        }
    }
#endif
