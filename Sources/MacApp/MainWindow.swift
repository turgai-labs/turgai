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
            // A hidden panel's button stays at the top, as its panel's header was.
            .frame(maxHeight: .infinity, alignment: .top)
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

/// A glass panel floating over the window, its corners concentric with the window's, as the
/// system's own sidebars are.
private struct FloatingPanel<Content: View>: View {
    let width: CGFloat
    @ViewBuilder let content: Content

    private var shape: ConcentricRectangle { ConcentricRectangle(corners: .concentric(minimum: 12), isUniform: true) }

    var body: some View {
        content
            .frame(width: width)
            .frame(maxHeight: .infinity)
            .clipShape(shape)
            .glassEffect(.regular, in: shape)
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

/// The conversations panel: the button that hides it; the space shown, whose name switches spaces,
/// and New conversation in it; then its conversations, the latest first, a dot marking one with
/// something new. A conversation renames from its menu.
private struct SidebarView: View {
    @Bindable var store: StoreOf<SidebarFeature>
    let hide: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HidePanelButton(systemImage: "sidebar.left", help: "Hide conversations", hide: hide)
                .padding(.horizontal, 12)
                .padding(.top, 12)
            HStack(spacing: 8) {
                SpaceSwitcher(store: store)
                Spacer(minLength: 0)
                Button {
                    store.send(.newConversationTapped)
                } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 28, height: 28)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.turgaiAccent)
                .help(store.newConversationHelp)
            }
            .padding(.leading, 16)
            .padding(.trailing, 12)
            .padding(.top, 10)
            .padding(.bottom, 12)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(store.entries) { (entry: SidebarFeature.Entry) in
                        ConversationLine(entry: entry) { store.send(.selected(entry.id)) }
                            .contextMenu {
                                Button("Rename…") { store.send(.renameConversationTapped(entry.id)) }
                            }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 12)
            }
            if let error = store.error {
                Text(error).font(.callout).foregroundStyle(Color.turgaiAccent).padding(12)
            }
        }
        .alert(store.naming?.title ?? "", isPresented: $store.isNaming.sending(\.namingPresented)) {
            TextField("Name", text: $store.name.sending(\.nameChanged))
            Button(store.naming?.confirmation ?? "") { store.send(.namingConfirmed) }
                .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) {}
        }
    }
}

/// The space shown, as Turgai's mark and its name: a menu of every space, with New space and, for
/// its admins, renaming it. A dot says something's new in another.
private struct SpaceSwitcher: View {
    let store: StoreOf<SidebarFeature>

    var body: some View {
        Menu {
            ForEach(store.spaceChoices) { (choice: SidebarFeature.SpaceChoice) in
                Button {
                    store.send(.spaceSwitched(choice.id))
                } label: {
                    if choice.isShown {
                        Label(choice.title, systemImage: "checkmark")
                    } else {
                        Text(choice.title)
                    }
                }
            }
            Divider()
            Button("New space…") { store.send(.newSpaceTapped) }
            if let rename = store.renameShownSpace {
                Button(rename) { store.send(.renameShownSpaceTapped) }
            }
        } label: {
            HStack(spacing: 6) {
                Image.skylark
                    .resizable()
                    .scaledToFit()
                    .frame(width: 20, height: 20)
                    .foregroundStyle(Color.turgaiAccent)
                Text(store.switcherTitle)
                    .font(.system(size: 18, weight: .heavy))
                    .tracking(-0.4)
                    .lineLimit(1)
                    .foregroundStyle(Color.turgaiInk)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.turgaiMuted)
                if store.unreadElsewhere {
                    Circle().fill(Color.turgaiAccent).frame(width: 7, height: 7)
                        .accessibilityLabel("New messages in another space")
                }
            }
            .contentShape(.rect)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .help("Switch spaces")
    }
}

/// A conversation: its name, a dot when something's new in it; while it's open, tinted and marked
/// with a bar in the accent.
private struct ConversationLine: View {
    let entry: SidebarFeature.Entry
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 6) {
                Text(entry.title)
                    .font(.system(size: 13, weight: entry.isEmphasized ? .semibold : .regular))
                    .lineLimit(1)
                    .foregroundStyle(Color.turgaiInk)
                Spacer(minLength: 0)
                if entry.unread {
                    Circle().fill(Color.turgaiAccent).frame(width: 7, height: 7)
                        .accessibilityLabel("New messages")
                }
            }
            .padding(.leading, 12)
            .padding(.trailing, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(alignment: .leading) {
                if entry.isOpen {
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 6).fill(Color.turgaiAccent.opacity(0.12))
                        RoundedRectangle(cornerRadius: 1.5).fill(Color.turgaiAccent).frame(width: 3)
                            .padding(.vertical, 5)
                    }
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}
