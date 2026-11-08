import ComposableArchitecture
import SwiftUI
import TurgaiModels

/// The main window, once someone is signed in: their conversations on the left, by space, and
/// every object they may see on the right, each in a glass panel floating over Turgai's field with
/// the button that hides it; a hidden panel leaves a button where it was to show it again. The open
/// conversation is between them.
struct MainWindow: View {
    let session: Session
    @Bindable var store: StoreOf<AppFeature>

    private static let sidebarWidth: CGFloat = 250
    private static let objectsWidth: CGFloat = 300
    /// Between a panel and the window's edge, and between a panel and the conversation.
    private static let gap: CGFloat = 10
    /// How wide the button that shows a hidden panel is.
    private static let showButtonWidth: CGFloat = 36

    var body: some View {
        ZStack {
            WorkingField()
            // The conversation keeps clear of the panels; the field runs under them.
            ChatView(
                session: session, title: store.sidebar.openTitle, store: store.scope(state: \.chat, action: \.chat)
            )
            .safeAreaPadding(.leading, (store.showsSidebar ? Self.sidebarWidth : Self.showButtonWidth) + Self.gap)
            .safeAreaPadding(.trailing, (store.showsObjects ? Self.objectsWidth : Self.showButtonWidth) + Self.gap)
            HStack(alignment: .top, spacing: 0) {
                if store.showsSidebar {
                    FloatingPanel(width: Self.sidebarWidth) {
                        SidebarView(store: store.scope(state: \.sidebar, action: \.sidebar)) {
                            store.send(.sidebarToggled, animation: .smooth)
                        }
                    }
                    .transition(.move(edge: .leading).combined(with: .opacity))
                } else {
                    ShowPanelButton(systemImage: "sidebar.left", help: "Show conversations") {
                        store.send(.sidebarToggled, animation: .smooth)
                    }
                }
                Spacer(minLength: 0)
                if store.showsObjects {
                    FloatingPanel(width: Self.objectsWidth) {
                        ObjectsPanel(store: store.scope(state: \.objects, action: \.objects)) {
                            store.send(.objectsToggled, animation: .smooth)
                        }
                    }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                } else {
                    ShowPanelButton(systemImage: "sidebar.right", help: "Show objects") {
                        store.send(.objectsToggled, animation: .smooth)
                    }
                }
            }
            .padding(Self.gap)
        }
        .task(id: session) { store.send(.sidebar(.appeared(session))) }
    }
}

/// The View menu's items for the window's panels, with the shortcut the conversations panel had.
struct PanelCommands: Commands {
    let store: StoreOf<AppFeature>

    var body: some Commands {
        CommandGroup(replacing: .sidebar) {
            Button(store.sidebarCommand) { store.send(.sidebarToggled, animation: .smooth) }
                .keyboardShortcut("s", modifiers: [.control, .command])
            Button(store.objectsCommand) { store.send(.objectsToggled, animation: .smooth) }
        }
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

/// Where a hidden panel was: a glass button that shows it again.
private struct ShowPanelButton: View {
    let systemImage: String
    let help: String
    let show: () -> Void

    var body: some View {
        Button(action: show) {
            Image(systemName: systemImage).frame(width: 20, height: 20)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .help(help)
    }
}

/// The button in a panel's header that hides it.
private struct HidePanelButton: View {
    let systemImage: String
    let help: String
    let hide: () -> Void

    var body: some View {
        Button(action: hide) {
            Image(systemName: systemImage).frame(width: 24, height: 24).contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.turgaiMuted)
        .help(help)
    }
}

/// The objects panel: its name and the button that hides it, over the objects.
private struct ObjectsPanel: View {
    let store: StoreOf<ObjectsFeature>
    let hide: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Objects").font(.headline).foregroundStyle(Color.turgaiInk)
                Spacer()
                HidePanelButton(systemImage: "sidebar.right", help: "Hide objects", hide: hide)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 6)
            ObjectsView(store: store)
        }
    }
}

/// The conversations panel: the button that hides it and Turgai's name; New conversation; then
/// each space with its conversations, the latest first, a dot marking one with something new; New
/// space at the bottom. A conversation, and a space to its admins, renames from its menu.
private struct SidebarView: View {
    @Bindable var store: StoreOf<SidebarFeature>
    let hide: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                HidePanelButton(systemImage: "sidebar.left", help: "Hide conversations", hide: hide)
                Wordmark()
            }
            .padding(.horizontal, 12)
            .padding(.top, 14)
            .padding(.bottom, 10)
            if let choice = store.newConversation {
                NewConversationButton(choice: choice) { store.send(.newConversationTapped(spaceID: $0)) }
                    .padding(.horizontal, 8)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(store.sections) { (section: SidebarFeature.Section) in
                        SpaceHeader(name: section.space.name)
                            .contextMenu {
                                if section.canRename {
                                    Button("Rename…") { store.send(.renameSpaceTapped(section.id)) }
                                }
                            }
                        ForEach(section.entries) { (entry: SidebarFeature.Entry) in
                            ConversationLine(entry: entry) { store.send(.selected(entry.id)) }
                                .contextMenu {
                                    Button("Rename…") { store.send(.renameConversationTapped(entry.id)) }
                                }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 12)
            }
            if let error = store.error {
                Text(error).font(.callout).foregroundStyle(Color.turgaiAccent).padding(12)
            }
            Button {
                store.send(.newSpaceTapped)
            } label: {
                Label("New space", systemImage: "plus")
                    .foregroundStyle(Color.turgaiMuted)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
        }
        .alert(store.naming?.title ?? "", isPresented: $store.isNaming.sending(\.namingPresented)) {
            TextField("Name", text: $store.name.sending(\.nameChanged))
            Button(store.naming?.confirmation ?? "") { store.send(.namingConfirmed) }
                .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) {}
        }
    }
}

/// New conversation: in the one space there is, or in one picked from a menu.
private struct NewConversationButton: View {
    let choice: SidebarFeature.NewConversation
    let start: (String) -> Void

    var body: some View {
        switch choice {
        case .inSpace(let space):
            Button {
                start(space)
            } label: {
                NewConversationLabel()
            }
            .buttonStyle(.plain)
        case .pick(let spaces):
            Menu {
                ForEach(spaces) { (space: SpaceSummary) in
                    Button(space.name) { start(space.id) }
                }
            } label: {
                NewConversationLabel()
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
        }
    }
}

/// What New conversation looks like: a line like a conversation's, in the accent.
private struct NewConversationLabel: View {
    var body: some View {
        Label("New conversation", systemImage: "square.and.pencil")
            .font(.body.weight(.semibold))
            .foregroundStyle(Color.turgaiAccent)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
    }
}

/// A space's name, over its conversations.
private struct SpaceHeader: View {
    let name: String

    var body: some View {
        Text(name)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Color.turgaiInk)
            .padding(.horizontal, 10)
            .padding(.top, 14)
            .padding(.bottom, 4)
    }
}

/// A conversation: its name, a dot when something's new in it, tinted while it's open.
private struct ConversationLine: View {
    let entry: SidebarFeature.Entry
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 6) {
                Text(entry.title).lineLimit(1).foregroundStyle(Color.turgaiInk)
                Spacer(minLength: 0)
                if entry.unread {
                    Circle().fill(Color.turgaiAccent).frame(width: 7, height: 7)
                        .accessibilityLabel("New messages")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(entry.isOpen ? Color.turgaiAccent.opacity(0.14) : .clear, in: .rect(cornerRadius: 8))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}
