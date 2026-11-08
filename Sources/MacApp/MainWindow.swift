import ComposableArchitecture
import SwiftUI
import TurgaiModels

/// The main window, once someone is signed in: Turgai's field behind everything, the open
/// conversation over it, and two glass panels floating over both, each with the button that hides
/// it: on the left one panel with the person's spaces on a rail and the shown space's
/// conversations, on the right every object they may see. A hidden panel leaves a button where it
/// was to show it again.
struct MainWindow: View {
    let session: Session
    @Bindable var store: StoreOf<AppFeature>

    private static let sidebarWidth: CGFloat = 300
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
                    GlassPanel(width: Self.sidebarWidth) {
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
                    GlassPanel(width: Self.objectsWidth) {
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
            // A hidden panel's button stays at the top, where its panel's header was.
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .modifier(SidebarDialogs(store: store.scope(state: \.sidebar, action: \.sidebar)))
        .task(id: session) { store.send(.sidebar(.appeared(session))) }
    }
}

/// The sidebar's dialog, over the whole window, so it shows whatever's hidden: renaming a
/// conversation or a space, or adding a space.
private struct SidebarDialogs: ViewModifier {
    @Bindable var store: StoreOf<SidebarFeature>

    func body(content: Content) -> some View {
        content.sheet(isPresented: $store.hasDialog.sending(\.dialogPresented)) {
            switch store.dialog {
            case .renaming(let renaming)?:
                RenameSheet(
                    title: renaming.title, name: $store.name.sending(\.nameChanged),
                    rename: { store.send(.renameConfirmed) }, cancel: { store.send(.dialogPresented(false)) })
            case .addingSpace(let adding)?:
                AddSpaceSheet(
                    adding: adding, name: $store.name.sending(\.nameChanged), link: $store.link.sending(\.linkChanged),
                    make: { store.send(.makeSpaceTapped) }, join: { store.send(.joinTapped) },
                    cancel: { store.send(.dialogPresented(false)) })
            case nil:
                EmptyView()
            }
        }
    }
}

/// A new name for a conversation or a space.
private struct RenameSheet: View {
    let title: String
    @Binding var name: String
    let rename: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline)
            TextField("Name", text: $name).onSubmit(rename)
            HStack {
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button("Rename", action: rename).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 340)
    }
}

/// A space to add: a new one, by its name, or one joined, by an invite's link; why it didn't work
/// when it didn't.
private struct AddSpaceSheet: View {
    let adding: SidebarFeature.AddingSpace
    @Binding var name: String
    @Binding var link: String
    let make: () -> Void
    let join: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New space").font(.headline)
            HStack {
                TextField("Name", text: $name).onSubmit(make)
                Button("Make", action: make).disabled(!adding.canMake)
            }
            Divider()
            Text("Join a space").font(.headline)
            HStack {
                TextField("turgai://join/…", text: $link).onSubmit(join)
                Button("Join", action: join).disabled(!adding.canJoin)
            }
            if let problem = adding.problem {
                Text(problem).font(.callout).foregroundStyle(Color.turgaiAccent)
            }
            HStack {
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 380)
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

/// A glass panel floating over the window: one surface of clear glass, faintly tinted so text on
/// it reads over the field's colors, its corners concentric with the window's.
private struct GlassPanel<Content: View>: View {
    let width: CGFloat
    @ViewBuilder let content: Content

    private var shape: ConcentricRectangle { ConcentricRectangle(corners: .concentric(minimum: 12), isUniform: true) }

    var body: some View {
        content
            .frame(width: width)
            .frame(maxHeight: .infinity)
            .clipShape(shape)
            .glassEffect(.clear.tint(Color.turgaiCanvas.opacity(0.3)), in: shape)
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
            Image(systemName: systemImage).frame(width: 26, height: 26).contentShape(.rect)
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
            .padding(.top, 12)
            .padding(.bottom, 4)
            ObjectsView(store: store)
        }
    }
}

/// The left panel, Slack's way, on one surface: the spaces on a rail under the button that hides
/// the panel, a hairline, then the shown space's name, New conversation in it, and its
/// conversations.
private struct SidebarView: View {
    let store: StoreOf<SidebarFeature>
    let hide: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            SpaceRail(store: store, hide: hide)
            Rectangle().fill(Color.turgaiInk.opacity(0.08)).frame(width: 1).padding(.vertical, 12)
            ConversationColumn(store: store)
        }
    }
}

/// Every space the person is in, under the button that hides the panel: a tile each with its
/// initial, filled in the accent while it's the one shown, as the open conversation is, and dotted
/// when something's new in it; + makes or joins one. It scrolls when there are many.
private struct SpaceRail: View {
    let store: StoreOf<SidebarFeature>
    let hide: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            HidePanelButton(systemImage: "sidebar.left", help: "Hide conversations", hide: hide)
                .padding(.top, 10)
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(store.spaceChoices) { (choice: SidebarFeature.SpaceChoice) in
                        SpaceTile(choice: choice) { store.send(.spaceSwitched(choice.id)) }
                    }
                    Button {
                        store.send(.addSpaceTapped)
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.turgaiMuted)
                            .frame(width: 30, height: 30)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .help("Make or join a space")
                }
                .padding(.vertical, 4)
            }
            .scrollIndicators(.never)
        }
        .frame(width: 50)
    }
}

/// A space's tile on the rail.
private struct SpaceTile: View {
    let choice: SidebarFeature.SpaceChoice
    let pick: () -> Void

    var body: some View {
        Button(action: pick) {
            Text(choice.initial)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(choice.isShown ? Color.white : Color.turgaiInk)
                .frame(width: 30, height: 30)
                .background(
                    choice.isShown ? Color.turgaiAccent : Color.turgaiInk.opacity(0.08), in: .rect(cornerRadius: 8)
                )
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topTrailing) {
            if choice.unread {
                Circle().fill(Color.turgaiAccent).frame(width: 8, height: 8).offset(x: 2, y: -2)
                    .accessibilityLabel("New messages")
            }
        }
        .help(choice.space.name)
    }
}

/// The shown space's name and New conversation in it, over its conversations, the latest first, a
/// dot marking one with something new. A conversation renames from its menu.
private struct ConversationColumn: View {
    let store: StoreOf<SidebarFeature>

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                SpaceHeading(name: store.shownSpaceName, rename: store.renameShownSpace) {
                    store.send(.renameShownSpaceTapped)
                }
                Spacer(minLength: 0)
                Button {
                    store.send(.newConversationTapped)
                } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 26, height: 26)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.turgaiAccent)
                .help(store.newConversationHelp)
            }
            .padding(.leading, 14)
            .padding(.trailing, 10)
            .padding(.top, 10)
            .padding(.bottom, 8)
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
    }
}

/// A conversation: its name, bolder with a dot when something's new in it; filled in the accent
/// while it's open, as the shown space's tile is.
private struct ConversationLine: View {
    let entry: SidebarFeature.Entry
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 6) {
                Text(entry.title)
                    .font(.system(size: 13, weight: entry.unread ? .semibold : .regular))
                    .lineLimit(1)
                    .foregroundStyle(entry.isOpen ? Color.white : Color.turgaiInk)
                Spacer(minLength: 0)
                if entry.unread {
                    Circle().fill(entry.isOpen ? Color.white : Color.turgaiAccent).frame(width: 7, height: 7)
                        .accessibilityLabel("New messages")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(entry.isOpen ? Color.turgaiAccent : .clear, in: .rect(cornerRadius: 8))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

/// The shown space's name, heading its conversations: for its admins, a menu that renames it.
private struct SpaceHeading: View {
    let name: String
    /// What renaming it says, when its person may: none otherwise.
    let rename: String?
    let renameTapped: () -> Void

    var body: some View {
        if let rename {
            Menu {
                Button(rename, action: renameTapped)
            } label: {
                HStack(spacing: 6) {
                    SpaceName(name: name)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color.turgaiMuted)
                }
                .contentShape(.rect)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
        } else {
            SpaceName(name: name)
        }
    }
}

/// A space's name, as its heading sets it.
private struct SpaceName: View {
    let name: String

    var body: some View {
        Text(name)
            .font(.system(size: 16, weight: .heavy))
            .tracking(-0.3)
            .lineLimit(1)
            .foregroundStyle(Color.turgaiInk)
    }
}
