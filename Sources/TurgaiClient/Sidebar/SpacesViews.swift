import ComposableArchitecture
import SwiftUI
import TurgaiModels

/// The spaces in use the person is in, the one something was last said in first: a tile each with
/// its initial, in its color, the shown one filled in, the others outlined, and dotted when
/// something's new in it. They scroll when there are many; under them, always there, + makes or
/// joins one, and Spaces lists every space, archived ones too.
///
/// It runs along `axis`: down a Mac's panel, across a phone's.
package struct SpaceRail: View {
    let store: StoreOf<SidebarFeature>
    let axis: Axis

    package init(store: StoreOf<SidebarFeature>, axis: Axis = .vertical) {
        self.store = store
        self.axis = axis
    }

    package var body: some View {
        switch axis {
        case .vertical:
            ScrollView {
                VStack(spacing: 12) {
                    SpaceTiles(store: store, axis: axis)
                    // What acts on the spaces, right after them: one made or joined, and every space.
                    VStack(spacing: 4) { RailButtons(store: store) }
                }
                // The rail's breadth, so what's drawn just outside a tile isn't cut off.
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
            .scrollIndicators(.never)
            .frame(width: 50)
        case .horizontal:
            HStack(spacing: 8) {
                ScrollView(.horizontal) {
                    // As tall as the system's own floating tab bar: 62 points, its 30-point tiles in the
                    // middle, and what's drawn just outside one isn't cut off.
                    SpaceTiles(store: store, axis: axis).padding(.horizontal, 14).padding(.vertical, 16)
                }
                .scrollIndicators(.never)
                // What acts on the spaces stays in reach, however many there are.
                HStack(spacing: 4) { RailButtons(store: store) }
            }
        }
    }
}

/// The spaces' tiles, one after another along `axis`.
private struct SpaceTiles: View {
    let store: StoreOf<SidebarFeature>
    let axis: Axis

    var body: some View {
        let along = axis == .vertical ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(spacing: 8))
        along {
            ForEach(store.spaceChoices) { (choice: SidebarFeature.SpaceChoice) in
                SpaceTile(choice: choice) { store.send(.spaceSwitched(choice.id)) }
            }
        }
    }
}

/// What acts on the spaces: one made or joined, and every space.
private struct RailButtons: View {
    let store: StoreOf<SidebarFeature>

    var body: some View {
        RailButton(symbol: "plus", help: "Make or join a space") { store.send(.addSpaceTapped) }
        RailButton(symbol: "square.grid.2x2", help: "All spaces (⌘K)") { store.send(.spacesTapped) }
    }
}

/// A button under the rail's tiles: its symbol, quiet.
private struct RailButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.panelGlyph)
                .foregroundStyle(Color.turgaiMuted)
                .frame(width: 30, height: 30)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// A space's tile on the rail: its stamp.
private struct SpaceTile: View {
    let choice: SidebarFeature.SpaceChoice
    let pick: () -> Void

    var body: some View {
        Button(action: pick) {
            SpaceMark(initial: choice.initial, hue: choice.hue, lean: choice.lean, fill: choice.fill)
        }
        .buttonStyle(.plain)
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

/// The shown space's conversations, the latest first, a dot marking one with something new, under
/// Conversations and New conversation while the space is in use; then its tasks. A conversation
/// renames, is left or is deleted from its menu; `open` opens one.
package struct ConversationList<Above: View>: View {
    let store: StoreOf<SidebarFeature>
    let open: (ConversationID) -> Void
    /// What scrolls with the conversations, above them.
    let above: Above

    package init(
        store: StoreOf<SidebarFeature>, open: @escaping (ConversationID) -> Void, @ViewBuilder above: () -> Above
    ) {
        self.store = store
        self.open = open
        self.above = above()
    }

    package var body: some View {
        ScrollView {
            // Grouped by nearness: a section's rows close together and its label close to them, the
            // sections far apart.
            LazyVStack(alignment: .leading, spacing: 0) {
                above
                if !store.entries.isEmpty || store.canStartConversation {
                    ConversationsHeading(space: store.shownSpace?.name, canStart: store.canStartConversation) {
                        store.send(.newConversationTapped)
                    }
                    .padding(.top, 16)
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(store.entries) { (entry: SidebarFeature.Entry) in
                            ConversationLine(entry: entry, hue: store.shownSpaceHue) {
                                open(entry.id)
                            }
                            .contextMenu {
                                ForEach(entry.menu) { (item: SidebarFeature.ConversationMenuItem) in
                                    ConversationMenuButton(item: item) {
                                        store.send(.conversationMenuPicked(entry.id, item))
                                    }
                                }
                            }
                            .transition(.opacity)
                        }
                    }
                }
                TasksSection(store: store.scope(\.tasks, action: \.tasks))
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 16)
            // A conversation or a task coming, going or moving up fades and moves into its place.
            .animation(.smooth(duration: 0.25), value: store.entries.map(\.id))
            .animation(.smooth(duration: 0.25), value: store.tasks.rows.ids)
        }
    }
}

/// A section's label in the shown space's column: a signpost in small capitals, tracked and muted,
/// so it doesn't compete with what it labels, whose weight says what's open or new.
package struct SectionLabel: View {
    let title: String

    package init(title: String) {
        self.title = title
    }

    package var body: some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .textCase(.uppercase)
            .tracking(0.8)
            .foregroundStyle(Color.turgaiMuted)
    }
}

/// Conversations, labelling the shown space's conversations, with New conversation on its line, by
/// what it adds to, while the space is in use: in the label's voice, as Tasks' arrow is, so the
/// heading is as tall as its label; inked while it's pointed at.
private struct ConversationsHeading: View {
    /// The shown space's name, once there is one.
    let space: String?
    let canStart: Bool
    let start: () -> Void
    @State private var pointedAt = false

    var body: some View {
        HStack(spacing: 5) {
            SectionLabel(title: "Conversations")
            Spacer(minLength: 0)
            if canStart {
                Button(action: start) {
                    Image(systemName: "square.and.pencil")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(pointedAt ? Color.turgaiInk : Color.turgaiMuted)
                        // Easier to hit than it is to see, without making the heading taller.
                        .contentShape(.rect.inset(by: -6))
                }
                .buttonStyle(.plain)
                .onHover { pointedAt = $0 }
                .help(space.map { "New conversation in \($0)" } ?? "New conversation")
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }
}

/// A conversation's menu item, as its menu words it.
private struct ConversationMenuButton: View {
    let item: SidebarFeature.ConversationMenuItem
    let pick: () -> Void

    var body: some View {
        switch item {
        case .rename: Button("Rename…", action: pick)
        case .leave: Button("Leave", action: pick)
        case .delete: Button("Delete…", role: .destructive, action: pick)
        }
    }
}

/// The shown space, heading its conversations: its name over what it is; for its admins, the name
/// is a menu that invites people to it, renames it, and archives it, or unarchives it.
package struct SpaceHeading: View {
    let name: String
    let archived: Bool
    /// How many people are in it, when there's more than one.
    let people: Int?
    /// What its menu offers, when its person is one of its admins: nothing otherwise.
    let menu: [SidebarFeature.SpaceMenuItem]
    let pick: (SidebarFeature.SpaceMenuItem) -> Void

    package init(
        name: String, archived: Bool, people: Int?, menu: [SidebarFeature.SpaceMenuItem],
        pick: @escaping (SidebarFeature.SpaceMenuItem) -> Void
    ) {
        self.name = name
        self.archived = archived
        self.people = people
        self.menu = menu
        self.pick = pick
    }

    package var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if !menu.isEmpty {
                Menu {
                    ForEach(menu) { (item: SidebarFeature.SpaceMenuItem) in
                        SpaceMenuButton(item: item, space: name) { pick(item) }
                    }
                } label: {
                    HStack(spacing: 4) {
                        SpaceName(name: name)
                        Image(systemName: "chevron.down")
                            .font(.caption.weight(.bold))
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
            SpaceDetail(archived: archived, people: people)
        }
    }
}

/// What a space's heading says under its name, when it tells something: that it's archived, and how
/// many people are in it.
private struct SpaceDetail: View {
    let archived: Bool
    let people: Int?

    var body: some View {
        switch (archived, people) {
        case (false, nil): EmptyView()
        case (true, nil): Text("Archived").font(.callout).foregroundStyle(Color.turgaiMuted)
        case (false, let people?): Text("\(people) people").font(.callout).foregroundStyle(Color.turgaiMuted)
        case (true, let people?):
            Text("Archived · \(people) people").font(.callout).foregroundStyle(Color.turgaiMuted)
        }
    }
}

/// A space's menu item, as its menu words it, for the space called `space`.
private struct SpaceMenuButton: View {
    let item: SidebarFeature.SpaceMenuItem
    let space: String
    let pick: () -> Void

    var body: some View {
        switch item {
        case .invite: Button("Invite People…", action: pick)
        case .bots: Button("Bots…", action: pick)
        case .connections: Button("Connections…", action: pick)
        case .rename: Button("Rename “\(space)”…", action: pick)
        case .archive: Button("Archive “\(space)”…", action: pick)
        case .unarchive: Button("Unarchive", action: pick)
        }
    }
}

/// A space's name, as its heading sets it.
private struct SpaceName: View {
    let name: String

    var body: some View {
        Text(name)
            .font(.largeTitle.weight(.heavy).width(.condensed))
            .lineLimit(1)
            .foregroundStyle(Color.turgaiInk)
    }
}

extension Font {
    /// Every glyph the left panel draws as a button of its own, in one voice: the sidebar's, a space
    /// made or joined, and every space. A section's buttons speak in its label's.
    package static var panelGlyph: Font { .title3.weight(.regular) }
}

/// The spaces on a rail, and with them `railFoot`, ruled off from the shown space's column: the
/// left section. Down its left side where there's room, as on a Mac or an iPad; along its foot,
/// in reach of a thumb, where there isn't, as on a phone.
package struct SpacesPanel<RailFoot: View>: View {
    let store: StoreOf<SidebarFeature>
    /// Which way the rail runs: down the panel's side, or across its foot.
    let rail: Axis
    let pages: StoreOf<PagesFeature>
    let openConversation: (ConversationID) -> Void
    let openPage: (PageAddress) -> Void
    /// Opens a page in a window of its own, where the app has windows.
    let openPageInWindow: ((PageAddress) -> Void)?
    let railFoot: RailFoot

    package init(
        store: StoreOf<SidebarFeature>, pages: StoreOf<PagesFeature>, rail: Axis = .vertical,
        openConversation: @escaping (ConversationID) -> Void, openPage: @escaping (PageAddress) -> Void,
        openPageInWindow: ((PageAddress) -> Void)? = nil, @ViewBuilder railFoot: () -> RailFoot
    ) {
        self.store = store
        self.rail = rail
        self.pages = pages
        self.openConversation = openConversation
        self.openPage = openPage
        self.openPageInWindow = openPageInWindow
        self.railFoot = railFoot()
    }

    package var body: some View {
        let column = SpaceColumn(
            store: store, pages: pages, openConversation: openConversation, openPage: openPage,
            openPageInWindow: openPageInWindow)
        switch rail {
        case .vertical:
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    SpaceRail(store: store)
                    railFoot.padding(.bottom, 12)
                }
                Rectangle().fill(Color.turgaiInk.opacity(0.15)).frame(width: 1).padding(.vertical, 8)
                column
            }
        case .horizontal:
            // What's listed scrolls under the rail, which floats over it on glass, as the system's
            // own tab bars do.
            column.safeAreaInset(edge: .bottom, spacing: 0) {
                HStack(spacing: 8) {
                    SpaceRail(store: store, axis: .horizontal)
                    railFoot.padding(.trailing, 12)
                }
                .clipShape(.capsule)
                .glassEffect(.regular.interactive(), in: .capsule)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
        }
    }
}

extension SpacesPanel where RailFoot == EmptyView {
    /// With nothing under the rail.
    package init(
        store: StoreOf<SidebarFeature>, pages: StoreOf<PagesFeature>,
        openConversation: @escaping (ConversationID) -> Void, openPage: @escaping (PageAddress) -> Void,
        openPageInWindow: ((PageAddress) -> Void)? = nil
    ) {
        self.init(
            store: store, pages: pages, openConversation: openConversation, openPage: openPage,
            openPageInWindow: openPageInWindow
        ) {
            EmptyView()
        }
    }
}

/// The shown space's column: its heading, whose menu acts on it; its pages, as small widgets; and
/// its conversations. Each opens beside it.
private struct SpaceColumn: View {
    let store: StoreOf<SidebarFeature>
    let pages: StoreOf<PagesFeature>
    let openConversation: (ConversationID) -> Void
    let openPage: (PageAddress) -> Void
    let openPageInWindow: ((PageAddress) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SpaceHeading(
                name: store.shownSpaceName, archived: store.shownSpaceIsArchived, people: store.shownSpacePeople,
                menu: store.shownSpaceMenu
            ) {
                store.send(.spaceMenuPicked($0))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // On the conversations' names' edge: the list's 8 and a line's 10.
            .padding(.leading, 18)
            .padding(.trailing, 10)
            .padding(.vertical, 12)
            // The column's head, ruled as the rail is: what's listed scrolls under it here.
            Rectangle().fill(Color.turgaiInk.opacity(0.15)).frame(height: 1)
            ConversationList(store: store, open: openConversation) {
                PageTiles(store: pages, open: openPage, openInWindow: openPageInWindow)
            }
            if let error = store.error {
                Text(error).font(.callout).foregroundStyle(Color.turgaiAccent).padding(12)
            }
        }
    }
}
