import ComposableArchitecture
import SwiftUI
import TurgaiModels

/// The main window, once someone is signed in: Turgai's field behind everything, the open
/// conversation over it, and a glass panel on the left, from the window's top, the traffic lights
/// in its corner and the button that hides it at its top right, with the person's spaces on a rail and
/// the shown space's conversations. Hidden, its glass draws into a button beside the traffic lights
/// that brings it back, and grows out of it again. The objects open in a window of their own.
struct MainWindow: View {
    let session: Session
    @Bindable var store: StoreOf<AppFeature>

    private static let sidebarWidth: CGFloat = 300
    /// Between the panel and the window's edges, and between the panel and the conversation.
    private static let gap: CGFloat = 10
    /// How much of the window's top left the traffic lights take.
    private static let trafficLightsWidth: CGFloat = 70
    /// The glass the panel and its show button share, so one morphs into the other.
    private static let sidebarGlass = "conversations"
    @Namespace private var glass

    var body: some View {
        ZStack {
            WorkingField()
            // The conversation keeps clear of the panel; the field runs under it.
            ChatView(
                session: session, title: store.sidebar.openTitle, store: store.scope(state: \.chat, action: \.chat)
            )
            .safeAreaPadding(.leading, (store.showsSidebar ? Self.sidebarWidth + Self.gap : 0) + Self.gap)
            .safeAreaPadding(.trailing, Self.gap)
            .toolbar {
                ToolbarItem(placement: .primaryAction) { ObjectsButton() }
                ToolbarItem(placement: .primaryAction) {
                    AccountButton(initial: store.accountInitial, name: store.me?.name) {
                        store.send(.signOutTapped)
                    }
                }
            }
            GlassEffectContainer(spacing: 24) {
                HStack(alignment: .top, spacing: 0) {
                    if store.showsSidebar {
                        GlassPanel(width: Self.sidebarWidth, glassID: Self.sidebarGlass, in: glass) {
                            SidebarView(store: store.scope(state: \.sidebar, action: \.sidebar)) {
                                store.send(.sidebarToggled, animation: .panelMorph)
                            }
                        }
                    } else {
                        ShowPanelButton(glassID: Self.sidebarGlass, in: glass) {
                            store.send(.sidebarToggled, animation: .panelMorph)
                        }
                        .padding(.leading, Self.trafficLightsWidth)
                    }
                    Spacer(minLength: 0)
                }
            }
            .padding(Self.gap)
            .frame(maxHeight: .infinity, alignment: .top)
            // From the window's top, as the system's own sidebars are: the traffic lights sit in it.
            .ignoresSafeArea(.container, edges: .top)
        }
        .modifier(SidebarDialogs(store: store.scope(state: \.sidebar, action: \.sidebar)))
        .task(id: session) {
            store.send(.sidebar(.appeared(session)))
            store.send(.accountAppeared(session))
        }
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
            case .inviting(let inviting)?:
                InviteSheet(
                    inviting: inviting, copy: { store.send(.copyInviteTapped) },
                    done: { store.send(.dialogPresented(false)) })
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

/// An invite to a space: its link, to copy and give someone, while it's made a moment, or why it
/// couldn't be.
private struct InviteSheet: View {
    let inviting: SidebarFeature.Inviting
    let copy: () -> Void
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(inviting.title).font(.headline)
            Text("Whoever opens this link joins. It works once.")
                .foregroundStyle(Color.turgaiMuted)
            if let link = inviting.link {
                Text(link)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.turgaiInk.opacity(0.05), in: .rect(cornerRadius: 8))
            } else if let problem = inviting.problem {
                Text(problem).font(.callout).foregroundStyle(Color.turgaiAccent)
            } else {
                ProgressView().controlSize(.small)
            }
            HStack {
                Spacer()
                Button("Copy Link", action: copy).disabled(inviting.link == nil)
                Button("Done", action: done).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 400)
    }
}

/// The View menu's items: the conversations panel, with the shortcut it had, and the objects'
/// window.
struct PanelCommands: Commands {
    let store: StoreOf<AppFeature>
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .sidebar) {
            Button(store.sidebarCommand) { store.send(.sidebarToggled, animation: .panelMorph) }
                .keyboardShortcut("s", modifiers: [.control, .command])
            Button("Objects") { openWindow(id: WindowID.objects) }
                .keyboardShortcut("o", modifiers: [.option, .command])
        }
    }
}

/// A glass panel floating over the window: one surface of regular glass, which blurs the field's
/// colors under it into the panel, its corners concentric with the window's.
private struct GlassPanel<Content: View>: View {
    let width: CGFloat
    /// The glass it shares with what it morphs into.
    let glassID: String
    let namespace: Namespace.ID
    let content: Content

    init(width: CGFloat, glassID: String, in namespace: Namespace.ID, @ViewBuilder content: () -> Content) {
        self.width = width
        self.glassID = glassID
        self.namespace = namespace
        self.content = content()
    }

    private var shape: ConcentricRectangle { ConcentricRectangle(corners: .concentric(minimum: 12), isUniform: true) }

    var body: some View {
        content
            .frame(width: width)
            .frame(maxHeight: .infinity)
            .clipShape(shape)
            .glassEffect(.regular, in: shape)
            .glassEffectID(glassID, in: namespace)
    }
}

/// Where the hidden panel's glass drew in: a glass circle that grows it out again.
private struct ShowPanelButton: View {
    /// The glass it shares with the panel.
    let glassID: String
    let namespace: Namespace.ID
    let show: () -> Void

    init(glassID: String, in namespace: Namespace.ID, show: @escaping () -> Void) {
        self.glassID = glassID
        self.namespace = namespace
        self.show = show
    }

    var body: some View {
        Button(action: show) {
            Image(systemName: "sidebar.left").frame(width: 32, height: 32).contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .glassEffectID(glassID, in: namespace)
        .help("Show conversations")
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

/// Who's signed in, as their initial in a circle: a menu with their name and Sign Out.
private struct AccountButton: View {
    let initial: String
    /// Their name, once it's read.
    let name: String?
    let signOut: () -> Void

    var body: some View {
        Menu {
            if let name {
                Text(name)
                Divider()
            }
            Button("Sign Out", action: signOut)
        } label: {
            Text(initial)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color.turgaiInk)
                .frame(width: 26, height: 26)
                .background(Color.turgaiInk.opacity(0.1), in: .circle)
        }
        .menuIndicator(.hidden)
        .help(name ?? "Account")
    }
}

/// Opens the objects' window.
private struct ObjectsButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button {
            openWindow(id: WindowID.objects)
        } label: {
            Label("Objects", systemImage: "cube")
        }
        .help("Objects")
    }
}

/// The left panel, Slack's way, on one surface: a row for the window's traffic lights, the button
/// that hides the panel at its other end; then the spaces on a rail, a hairline, and the shown
/// space's heading, New conversation in it, and its conversations.
private struct SidebarView: View {
    let store: StoreOf<SidebarFeature>
    let hide: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                HidePanelButton(systemImage: "sidebar.left", help: "Hide conversations", hide: hide)
            }
            .padding(.trailing, 10)
            .frame(height: 32)
            HStack(spacing: 0) {
                SpaceRail(store: store)
                Rectangle().fill(Color.turgaiInk.opacity(0.08)).frame(width: 1).padding(.vertical, 8)
                ConversationColumn(store: store)
            }
        }
    }
}

/// Every space the person is in: a tile each with its initial, the shown one darker with a bar
/// beside it, Slack's way, and dotted when something's new in it; + makes or joins one. It scrolls
/// when there are many.
private struct SpaceRail: View {
    let store: StoreOf<SidebarFeature>

    var body: some View {
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
            .padding(.vertical, 10)
        }
        .scrollIndicators(.never)
        .frame(width: 50)
    }
}

/// A space's tile on the rail.
private struct SpaceTile: View {
    let choice: SidebarFeature.SpaceChoice
    let pick: () -> Void

    var body: some View {
        Button(action: pick) {
            SpaceMark(initial: choice.initial, isShown: choice.isShown)
        }
        .buttonStyle(.plain)
        .overlay(alignment: .leading) {
            if choice.isShown {
                RoundedRectangle(cornerRadius: 1.5).fill(Color.turgaiInk).frame(width: 3, height: 18).offset(x: -8)
            }
        }
        .overlay(alignment: .topTrailing) {
            if choice.unread {
                Circle().fill(Color.turgaiAccent).frame(width: 8, height: 8).offset(x: 2, y: -2)
                    .accessibilityLabel("New messages")
            }
        }
        .help(choice.space.name)
    }
}

/// A space's mark: its initial on a tile, darker when it's the one shown.
private struct SpaceMark: View {
    let initial: String
    let isShown: Bool

    var body: some View {
        Text(initial)
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(isShown ? Color.turgaiInk : Color.turgaiMuted)
            .frame(width: 30, height: 30)
            .background(Color.turgaiInk.opacity(isShown ? 0.16 : 0.06), in: .rect(cornerRadius: 8))
            .contentShape(.rect)
    }
}

/// The shown space's name and New conversation in it, over its conversations, the latest first, a
/// dot marking one with something new. A conversation renames from its menu.
private struct ConversationColumn: View {
    let store: StoreOf<SidebarFeature>

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                SpaceHeading(
                    initial: store.shownSpaceInitial, name: store.shownSpaceName, detail: store.shownSpaceDetail,
                    menu: store.shownSpaceMenu, rename: { store.send(.renameShownSpaceTapped) },
                    invite: { store.send(.inviteTapped) })
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

/// A conversation: its name, bolder with a dot when something's new in it; on a quiet fill, bolder,
/// while it's open.
private struct ConversationLine: View {
    let entry: SidebarFeature.Entry
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 6) {
                Text(entry.title)
                    .font(.system(size: 13, weight: entry.unread || entry.isOpen ? .semibold : .regular))
                    .lineLimit(1)
                    .foregroundStyle(Color.turgaiInk)
                Spacer(minLength: 0)
                if entry.unread {
                    Circle().fill(Color.turgaiAccent).frame(width: 7, height: 7)
                        .accessibilityLabel("New messages")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.turgaiInk.opacity(entry.isOpen ? 0.08 : 0), in: .rect(cornerRadius: 8))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

/// The shown space, heading its conversations: its mark, as the rail has it, and its name over
/// what it is; for its admins, the name is a menu that invites people to it and renames it.
private struct SpaceHeading: View {
    let initial: String
    let name: String
    /// What it is and who's in it.
    let detail: String
    /// What its menu offers, when its person is one of its admins: none otherwise.
    let menu: SidebarFeature.SpaceMenu?
    let rename: () -> Void
    let invite: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            SpaceMark(initial: initial, isShown: true)
            VStack(alignment: .leading, spacing: 1) {
                if let menu {
                    Menu {
                        Button(menu.invite, action: invite)
                        Button(menu.rename, action: rename)
                    } label: {
                        HStack(spacing: 4) {
                            SpaceName(name: name)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 9, weight: .bold))
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
                Text(detail).font(.caption).foregroundStyle(Color.turgaiMuted)
            }
        }
    }
}

/// A space's name, as its heading sets it.
private struct SpaceName: View {
    let name: String

    var body: some View {
        Text(name)
            .font(.system(size: 15, weight: .bold))
            .tracking(-0.2)
            .lineLimit(1)
            .foregroundStyle(Color.turgaiInk)
    }
}

extension Animation {
    /// How the panel's glass draws into its show button and grows out of it.
    fileprivate static let panelMorph = Animation.spring(duration: 0.45, bounce: 0.18)
}
