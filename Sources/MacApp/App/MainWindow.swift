import ComposableArchitecture
import SwiftUI
import TurgaiModels

/// The main window, once someone is signed in: Turgai's field behind everything, the open
/// conversation over it, and a glass panel on the left, from the window's top, the traffic lights
/// in its corner and the button that hides it just after them, with the person's spaces on a rail
/// and the shown space's conversations. Hidden, its glass shrinks into a button in the same place
/// that brings it back, and grows out of it again. The objects open in a window of their own.
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
            ChatView(title: store.sidebar.openTitle, store: chat)
                // Only the panel's room: what's in the conversation keeps its own margins.
                .safeAreaPadding(.leading, chatInset)
                .toolbar { WindowToolbar(initial: store.profile.initial, name: store.profile.me?.name) }
            LeftPanel(store: store, width: Self.sidebarWidth)
                .padding(Self.gap)
                // From the window's top, as the system's own sidebars are: the traffic lights sit in it.
                .ignoresSafeArea(.container, edges: .top)
        }
        .modifier(SidebarDialogs(store: sidebar))
        .task(id: session) { await appeared() }
    }

    /// Someone's signed in as `session`: who they are is read, and the sidebar hears the connection
    /// while the window's shown.
    private func appeared() async {
        store.send(.profile(.appeared(session)))
        await store.send(.sidebar(.appeared(session))).finish()
    }

    private var chat: StoreOf<ChatFeature> {
        store.scope(\.chat, action: \.chat)
    }

    private var sidebar: StoreOf<SidebarFeature> {
        store.scope(\.sidebar, action: \.sidebar)
    }

    /// How far the conversation keeps from the window's leading edge: the panel's room, when it's
    /// shown.
    private var chatInset: CGFloat {
        store.showsSidebar ? Self.sidebarWidth + Self.gap : 0
    }
}

/// The window's toolbar: the objects, and who's signed in.
private struct WindowToolbar: ToolbarContent {
    let initial: String
    /// Their name, once it's read.
    let name: String?

    var body: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) { ObjectsButton() }
        ToolbarItem(placement: .primaryAction) { AccountButton(initial: initial, name: name) }
            // A stamp of its own, not on the toolbar's glass.
            .sharedBackgroundVisibility(.hidden)
    }
}

/// The left panel's glass, as tall as the window and `width` wide when shown.
private struct LeftPanel: View {
    let store: StoreOf<AppFeature>
    let width: CGFloat

    var body: some View {
        GeometryReader { geometry in
            SidebarGlass(
                isShown: store.showsSidebar, size: CGSize(width: width, height: geometry.size.height),
                store: store.scope(\.sidebar, action: \.sidebar)
            ) {
                withAnimation(.panelMorph) { _ = store.send(.sidebarToggled) }
            }
        }
    }
}

/// The View menu's items: the conversations panel, with the shortcut it had, every space, and the
/// objects' window.
struct PanelCommands: Commands {
    let store: StoreOf<AppFeature>
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .sidebar) {
            Button(store.sidebarCommand) { withAnimation(.panelMorph) { _ = store.send(.sidebarToggled) } }
                .keyboardShortcut("s", modifiers: [.control, .command])
            Button("Spaces…") { store.send(.sidebar(.spacesTapped)) }
                .keyboardShortcut("k", modifiers: .command)
            Button("Objects") { openWindow(id: WindowID.objects) }
                .keyboardShortcut("o", modifiers: [.option, .command])
        }
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
                .font(.headline.weight(.heavy))
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

extension Animation {
    /// How the panel's glass draws into its show button and grows out of it.
    fileprivate static let panelMorph = Animation.spring(duration: 0.45, bounce: 0.18)
}
