import ComposableArchitecture
import SwiftUI
import TurgaiModels

/// The main window, once someone is signed in: their conversations on the left, by space, the one
/// open beside them, and, when asked for, every object they may see in a glass panel on the right.
struct MainWindow: View {
    let session: Session
    @Bindable var store: StoreOf<AppFeature>
    @State private var objects: StoreOf<ObjectsFeature>
    @State private var showsObjects = false

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
        NavigationSplitView {
            SidebarView(store: store.scope(state: \.sidebar, action: \.sidebar))
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 360)
        } detail: {
            ChatView(session: session, title: title, store: store.scope(state: \.chat, action: \.chat))
                .overlay(alignment: .trailing) {
                    if showsObjects {
                        ObjectsView(store: objects)
                            .frame(width: 320)
                            .padding(.vertical, 8)
                            .glassEffect(.regular, in: .rect(cornerRadius: 20))
                            .padding(.top, 80)
                            .padding([.bottom, .trailing], 16)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .overlay(alignment: .topTrailing) {
                    Button {
                        withAnimation(.smooth) { showsObjects.toggle() }
                    } label: {
                        Image(systemName: "sidebar.right").frame(width: 22, height: 22)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .help(showsObjects ? "Hide objects" : "Show objects")
                    // Level with the conversation's name, clear of the window's edge.
                    .padding(.top, 36)
                    .padding(.trailing, 16)
                }
        }
        .task(id: session) { store.send(.sidebar(.appeared(session))) }
    }

    /// What the open conversation is called.
    private var title: String {
        store.sidebar.selected.flatMap { store.sidebar.conversations[id: $0]?.title } ?? "New conversation"
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
