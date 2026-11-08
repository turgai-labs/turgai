import ComposableArchitecture
import SwiftUI
import TurgaiModels

/// The main window, once someone is signed in, built from the system's split view so the system
/// draws its Liquid Glass: the sidebar holds the person's spaces on a rail and the shown space's
/// conversations; the open conversation is the detail, over Turgai's field; the objects they may
/// see are its inspector.
struct MainWindow: View {
    let session: Session
    @Bindable var store: StoreOf<AppFeature>

    var body: some View {
        NavigationSplitView(columnVisibility: $store.sidebarVisibility) {
            SidebarView(store: store.scope(state: \.sidebar, action: \.sidebar))
                .navigationSplitViewColumnWidth(min: 260, ideal: 290, max: 380)
        } detail: {
            ChatView(
                session: session, title: store.sidebar.openTitle, store: store.scope(state: \.chat, action: \.chat)
            )
            .background { WorkingField().backgroundExtensionEffect() }
            .inspector(isPresented: $store.showsObjects) {
                ObjectsPanel(store: store.scope(state: \.objects, action: \.objects))
                    .inspectorColumnWidth(min: 260, ideal: 300, max: 440)
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        store.send(.objectsToggled, animation: .smooth)
                    } label: {
                        Label("Objects", systemImage: "sidebar.right")
                    }
                    .help(store.objectsCommand)
                }
            }
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

/// The objects, under their name.
private struct ObjectsPanel: View {
    let store: StoreOf<ObjectsFeature>

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Objects")
                .font(.headline)
                .foregroundStyle(Color.turgaiInk)
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 4)
            ObjectsView(store: store)
        }
    }
}

/// The sidebar, Slack's way, on one surface: the spaces on a rail, then the shown space's name,
/// New conversation in it, and its conversations.
private struct SidebarView: View {
    let store: StoreOf<SidebarFeature>

    var body: some View {
        HStack(spacing: 0) {
            SpaceRail(store: store)
            Divider()
            ConversationColumn(store: store)
        }
    }
}

/// Every space the person is in: a tile each with its initial, filled in the accent while it's the
/// one shown, as a chosen conversation is, and dotted when something's new in it; + makes or joins
/// one. It scrolls when there are many.
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
            .padding(.vertical, 8)
        }
        .scrollIndicators(.never)
        .frame(width: 46)
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
                    choice.isShown ? Color.turgaiAccent : Color.primary.opacity(0.07), in: .rect(cornerRadius: 8)
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

/// The shown space's name and New conversation in it, over its conversations: the system's sidebar
/// list, the latest first, a dot marking one with something new. A conversation renames from its
/// menu.
private struct ConversationColumn: View {
    @Bindable var store: StoreOf<SidebarFeature>

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
            .padding(.leading, 16)
            .padding(.trailing, 12)
            .padding(.top, 10)
            .padding(.bottom, 4)
            List(selection: $store.selected.sending(\.selectionChanged)) {
                ForEach(store.entries) { (entry: SidebarFeature.Entry) in
                    ConversationRow(entry: entry)
                        .tag(entry.id)
                        .contextMenu {
                            Button("Rename…") { store.send(.renameConversationTapped(entry.id)) }
                        }
                }
            }
            .listStyle(.sidebar)
            .tint(Color.turgaiAccent)
            if let error = store.error {
                Text(error).font(.callout).foregroundStyle(Color.turgaiAccent).padding(12)
            }
        }
    }
}

/// A conversation in the list: its name, bolder with a dot when something's new in it.
private struct ConversationRow: View {
    let entry: SidebarFeature.Entry

    var body: some View {
        HStack(spacing: 6) {
            Text(entry.title)
                .fontWeight(entry.unread ? .semibold : .regular)
                .lineLimit(1)
            Spacer(minLength: 0)
            if entry.unread {
                Circle().fill(Color.turgaiAccent).frame(width: 7, height: 7)
                    .accessibilityLabel("New messages")
            }
        }
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
