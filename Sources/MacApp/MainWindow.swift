import ComposableArchitecture
import SwiftUI
import TurgaiModels

/// The main window, once someone is signed in: their conversations on the left, by space, and
/// every object they may see on the right, each in a glass panel floating over the window, which
/// the toolbar shows and hides; the open conversation between them.
struct MainWindow: View {
    let session: Session
    @Bindable var store: StoreOf<AppFeature>
    @State private var objects: StoreOf<ObjectsFeature>

    private static let sidebarWidth: CGFloat = 250
    private static let objectsWidth: CGFloat = 300
    /// Between a panel and the window's edge, and between a panel and the conversation.
    private static let gap: CGFloat = 10

    init(session: Session, store: StoreOf<AppFeature>, objects: ObjectsClient) {
        self.session = session
        self.store = store
        _objects = State(
            initialValue: Store(initialState: ObjectsFeature.State()) {
                ObjectsFeature()
            } withDependencies: {
                $0.objects = objects
            })
    }

    var body: some View {
        ZStack {
            // The conversation keeps clear of the panels; its background runs under them.
            ChatView(
                session: session, title: store.sidebar.openTitle, store: store.scope(state: \.chat, action: \.chat)
            )
            .safeAreaPadding(.leading, store.showsSidebar ? Self.sidebarWidth + Self.gap : 0)
            .safeAreaPadding(.trailing, store.showsObjects ? Self.objectsWidth + Self.gap : 0)
            HStack(spacing: 0) {
                if store.showsSidebar {
                    FloatingPanel(width: Self.sidebarWidth) {
                        SidebarView(store: store.scope(state: \.sidebar, action: \.sidebar))
                    }
                    .transition(.move(edge: .leading).combined(with: .opacity))
                }
                Spacer(minLength: 0)
                if store.showsObjects {
                    FloatingPanel(width: Self.objectsWidth) { ObjectsView(store: objects) }
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .padding(Self.gap)
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    store.send(.sidebarToggled, animation: .smooth)
                } label: {
                    Label("Conversations", systemImage: "sidebar.left")
                }
                .keyboardShortcut("s", modifiers: [.control, .command])
                .help(store.showsSidebar ? "Hide conversations" : "Show conversations")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    store.send(.objectsToggled, animation: .smooth)
                } label: {
                    Label("Objects", systemImage: "sidebar.right")
                }
                .help(store.showsObjects ? "Hide objects" : "Show objects")
            }
        }
        .task(id: session) { store.send(.sidebar(.appeared(session))) }
    }
}

/// A glass panel floating over the window.
private struct FloatingPanel<Content: View>: View {
    let width: CGFloat
    @ViewBuilder let content: Content

    var body: some View {
        content
            .frame(width: width)
            .frame(maxHeight: .infinity)
            .clipShape(.rect(cornerRadius: 24))
            .glassEffect(.regular, in: .rect(cornerRadius: 24))
    }
}

/// The person's spaces, each with its conversations, the latest first: a dot marks one with
/// something new, and ✎ starts one in its space.
private struct SidebarView: View {
    let store: StoreOf<SidebarFeature>

    var body: some View {
        List(selection: selection) {
            ForEach(store.spaces) { (space: SpaceSummary) in
                Section {
                    ForEach(store.conversations.filter { $0.spaceID == space.id }) { (row: SidebarFeature.Row) in
                        HStack {
                            Text(row.title ?? "New conversation").lineLimit(1)
                            Spacer()
                            if row.unread {
                                Circle().fill(Color.turgaiAccent).frame(width: 8, height: 8)
                                    .accessibilityLabel("New messages")
                            }
                        }
                        .tag(row.id)
                    }
                } header: {
                    HStack {
                        Text(space.name)
                        Spacer()
                        Button {
                            store.send(.newConversationTapped(spaceID: space.id))
                        } label: {
                            Image(systemName: "square.and.pencil")
                        }
                        .buttonStyle(.plain)
                        .help("New conversation in \(space.name)")
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .safeAreaInset(edge: .bottom) {
            if let error = store.error {
                Text(error).font(.callout).foregroundStyle(Color.turgaiAccent).padding(8)
            }
        }
    }

    private var selection: Binding<ConversationID?> {
        Binding(
            get: { store.selected },
            set: { if let id = $0 { store.send(.selected(id)) } }
        )
    }
}
