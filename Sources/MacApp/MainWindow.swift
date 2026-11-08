import ComposableArchitecture
import SwiftUI
import TurgaiModels

/// The main window, once someone is signed in: Turgai's field behind everything, the open
/// conversation over it, and a glass panel on the left, from the window's top, the traffic lights
/// in its corner and the button that hides it at its top right, with the person's spaces on a rail and
/// the shown space's conversations. Hidden, its glass shrinks into a button beside the traffic
/// lights that brings it back, and grows out of it again. The objects open in a window of their own.
struct MainWindow: View {
    let session: Session
    @Bindable var store: StoreOf<AppFeature>

    private static let sidebarWidth: CGFloat = 300
    /// Between the panel and the window's edges, and between the panel and the conversation.
    private static let gap: CGFloat = 10

    var body: some View {
        ZStack {
            WorkingField(hue: store.sidebar.shownSpaceHue)
            // The conversation keeps clear of the panel; the field runs under it.
            ChatView(
                title: store.sidebar.openTitle, store: store.scope(state: \.chat, action: \.chat)
            )
            // Only the panel's room: what's in the conversation keeps its own margins.
            .safeAreaPadding(.leading, store.showsSidebar ? Self.sidebarWidth + Self.gap : 0)
            .toolbar {
                ToolbarItem(placement: .primaryAction) { ObjectsButton() }
                ToolbarItem(placement: .primaryAction) {
                    AccountButton(initial: store.profile.initial, name: store.profile.me?.name)
                }
                // A stamp of its own, not on the toolbar's glass.
                .sharedBackgroundVisibility(.hidden)
            }
            GeometryReader { geometry in
                SidebarGlass(
                    isShown: store.showsSidebar, size: CGSize(width: Self.sidebarWidth, height: geometry.size.height),
                    store: store.scope(state: \.sidebar, action: \.sidebar)
                ) {
                    store.send(.sidebarToggled, animation: .panelMorph)
                }
            }
            .padding(Self.gap)
            // From the window's top, as the system's own sidebars are: the traffic lights sit in it.
            .ignoresSafeArea(.container, edges: .top)
        }
        .modifier(SidebarDialogs(store: store.scope(state: \.sidebar, action: \.sidebar)))
        .task(id: session) {
            store.send(.sidebar(.appeared(session)))
            store.send(.profile(.appeared(session)))
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

/// The left panel and the button it shrinks into, as one glass shape: shown, the panel of `size`;
/// hidden, a glass circle beside the window's traffic lights. Its frame is what animates, so the
/// panel's content, kept at its full size and clipped by the glass, is drawn into the button as it
/// fades, and out of it again.
private struct SidebarGlass: View {
    let isShown: Bool
    /// The panel's size, shown.
    let size: CGSize
    let store: StoreOf<SidebarFeature>
    let toggle: () -> Void

    /// How much of the window's top left the traffic lights take, with room after them.
    private static let trafficLightsWidth: CGFloat = 86
    private static let buttonSize: CGFloat = 32
    private static let shape = RoundedRectangle(cornerRadius: 16)

    var body: some View {
        ZStack(alignment: .topLeading) {
            if isShown {
                SidebarView(store: store, hide: toggle)
                    .frame(width: size.width, height: size.height, alignment: .topLeading)
                    .transition(.opacity)
            } else {
                Button(action: toggle) {
                    Image(systemName: "sidebar.left")
                        .frame(width: Self.buttonSize, height: Self.buttonSize)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help("Show conversations")
                .transition(.opacity)
            }
        }
        .frame(
            width: isShown ? size.width : Self.buttonSize, height: isShown ? size.height : Self.buttonSize,
            alignment: .topLeading
        )
        .clipShape(Self.shape)
        .glassEffect(.regular, in: Self.shape)
        .padding(.leading, isShown ? 0 : Self.trafficLightsWidth)
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

/// Who's signed in, as their initial on a stamp of their messages' yellow: it opens their profile.
private struct AccountButton: View {
    let initial: String
    /// Their name, once it's read.
    let name: String?
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button {
            openWindow(id: WindowID.profile)
        } label: {
            Text(initial)
                .font(.system(size: 13, weight: .heavy))
                .foregroundStyle(Color.inkOnSignal)
                .frame(width: 28, height: 28)
                .background(StampBackground(color: .bubbleYours, lean: Lean(degrees: 4)))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(name ?? "Profile")
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

/// Every space the person is in: a tile each with its initial, in its color, the shown one with a
/// bar beside it, Slack's way, and dotted when something's new in it; + makes or joins one. It
/// scrolls when there are many.
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

/// A space's tile on the rail: its stamp.
private struct SpaceTile: View {
    let choice: SidebarFeature.SpaceChoice
    let pick: () -> Void

    var body: some View {
        Button(action: pick) {
            SpaceMark(initial: choice.initial, hue: choice.hue, lean: choice.lean)
        }
        .buttonStyle(.plain)
        .overlay(alignment: .leading) {
            if choice.isShown {
                RoundedRectangle(cornerRadius: 1.5).fill(Color.turgaiInk).frame(width: 3, height: 18).offset(x: -8)
            }
        }
        .overlay(alignment: .topTrailing) {
            if choice.unread {
                Circle().fill(Color.turgaiAccent).frame(width: 8, height: 8)
                    .overlay(Circle().stroke(Color.white, lineWidth: 1.5))
                    .offset(x: 3, y: -3)
                    .accessibilityLabel("New messages")
            }
        }
        .help(choice.space.name)
    }
}

/// A space's mark: its initial on a stamp of its color.
private struct SpaceMark: View {
    let initial: String
    let hue: SpaceHue
    let lean: Lean

    var body: some View {
        Text(initial)
            .font(.system(size: 14, weight: .heavy))
            .foregroundStyle(hue.ink)
            .frame(width: 30, height: 30)
            .background(StampBackground(color: hue.color, lean: lean))
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
                    name: store.shownSpaceName, detail: store.shownSpaceDetail, menu: store.shownSpaceMenu,
                    rename: { store.send(.renameShownSpaceTapped) }, invite: { store.send(.inviteTapped) })
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
                        ConversationLine(entry: entry, hue: store.shownSpaceHue) { store.send(.selected(entry.id)) }
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

/// A conversation: its name, bolder with a dot when something's new in it; on a stamp of its space's
/// color, bolder, while it's open.
private struct ConversationLine: View {
    let entry: SidebarFeature.Entry
    /// Its space's color.
    let hue: SpaceHue
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 6) {
                Text(entry.title)
                    .font(.system(size: 13, weight: entry.unread || entry.isOpen ? .semibold : .regular))
                    .lineLimit(1)
                    .foregroundStyle(entry.isOpen ? hue.ink : Color.turgaiInk)
                Spacer(minLength: 0)
                if entry.unread {
                    Circle().fill(Color.turgaiAccent).frame(width: 7, height: 7)
                        .accessibilityLabel("New messages")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(StampBackground(color: entry.isOpen ? hue.color : .clear, lean: entry.lean))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

/// The shown space, heading its conversations: its name over what it is; for its admins, the name
/// is a menu that invites people to it and renames it.
private struct SpaceHeading: View {
    let name: String
    /// What it is and who's in it.
    let detail: String
    /// What its menu offers, when its person is one of its admins: none otherwise.
    let menu: SidebarFeature.SpaceMenu?
    let rename: () -> Void
    let invite: () -> Void

    var body: some View {
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

/// A space's name, as its heading sets it.
private struct SpaceName: View {
    let name: String

    var body: some View {
        Text(name)
            .font(.system(size: 20, weight: .heavy).width(.condensed))
            .lineLimit(1)
            .foregroundStyle(Color.turgaiInk)
    }
}

extension Animation {
    /// How the panel's glass draws into its show button and grows out of it.
    fileprivate static let panelMorph = Animation.spring(duration: 0.45, bounce: 0.18)
}
