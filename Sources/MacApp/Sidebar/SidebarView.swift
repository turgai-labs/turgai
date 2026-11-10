import ComposableArchitecture
import SwiftUI
import TurgaiModels

/// The left panel and the button it shrinks into, as one glass shape: shown, the panel of `size`;
/// hidden, a glass circle beside the window's traffic lights. Its frame is what animates, so the
/// panel's content, kept at its full size and clipped by the glass, is drawn into the button as it
/// fades, and out of it again. The button that shows and hides it is one, just after the traffic
/// lights either way: it stays where it is while the glass changes around it.
struct SidebarGlass: View {
    let isShown: Bool
    /// The panel's size, shown.
    let size: CGSize
    let store: StoreOf<SidebarFeature>
    let toggle: () -> Void

    /// How much of the window's top left the traffic lights take, with room after them.
    private static let trafficLightsWidth: CGFloat = 86
    static let buttonSize: CGFloat = 32
    private static let shape = RoundedRectangle(cornerRadius: 16)

    var body: some View {
        ZStack(alignment: .topLeading) {
            if isShown {
                SidebarView(store: store)
                    .frame(width: size.width, height: size.height, alignment: .topLeading)
                    .transition(.opacity)
            }
            Button(action: toggle) {
                Image(systemName: "sidebar.left")
                    .font(.panelGlyph)
                    .frame(width: Self.buttonSize, height: Self.buttonSize)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .foregroundStyle(isShown ? Color.turgaiMuted : Color.primary)
            .help(isShown ? "Hide conversations" : "Show conversations")
            // Where the traffic lights end, inside the panel or as the glass itself: the same place.
            .padding(.leading, isShown ? Self.trafficLightsWidth : 0)
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

/// The left panel, Slack's way, on one surface: a row for the window's traffic lights and the button
/// that hides it; then the spaces on a rail, a hairline, and the shown space's heading, New
/// conversation in it, and its conversations.
private struct SidebarView: View {
    let store: StoreOf<SidebarFeature>

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: SidebarGlass.buttonSize)
            HStack(spacing: 0) {
                SpaceRail(store: store)
                Rectangle().fill(Color.turgaiInk.opacity(0.15)).frame(width: 1).padding(.vertical, 8)
                ConversationColumn(store: store)
            }
        }
    }
}

/// The spaces in use the person is in, the one something was last said in first: a tile each with
/// its initial, in its color, the shown one filled in, the others outlined, and dotted when
/// something's new in it. They scroll when there are many; under them, always there, + makes or
/// joins one, and Spaces lists every space, archived ones too.
private struct SpaceRail: View {
    let store: StoreOf<SidebarFeature>

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                VStack(spacing: 8) {
                    ForEach(store.spaceChoices) { (choice: SidebarFeature.SpaceChoice) in
                        SpaceTile(choice: choice) { store.send(.spaceSwitched(choice.id)) }
                    }
                }
                // What acts on the spaces, right under them: one made or joined, and every space.
                VStack(spacing: 4) {
                    RailButton(symbol: "plus", help: "Make or join a space") { store.send(.addSpaceTapped) }
                    RailButton(symbol: "square.grid.2x2", help: "All spaces (⌘K)") { store.send(.spacesTapped) }
                }
            }
            // The rail's width, so what's drawn just outside a tile isn't cut off; its first tile on
            // the line the space's name starts on.
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }
        .scrollIndicators(.never)
        .frame(width: 50)
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

/// A space's mark: its initial on a stamp of its color, or, outlined, in its deep shade inside the
/// stamp's outline.
struct SpaceMark: View {
    let initial: String
    let hue: SpaceHue
    let lean: Lean
    let fill: StampFill

    var body: some View {
        Text(initial)
            .font(.title3.weight(.heavy).width(.condensed))
            .foregroundStyle(fill == .filled ? hue.ink : hue.deep)
            .frame(width: 30, height: 30)
            .background {
                switch fill {
                case .filled: StampBackground(color: hue.color, lean: lean)
                case .outlined: StampOutline(color: hue.deep, lean: lean)
                }
            }
            .contentShape(.rect)
    }
}

/// The shown space's name and New conversation in it, while it's in use, ruled off from its
/// conversations, the latest first, a dot marking one with something new. A conversation renames,
/// is left or is deleted from its menu.
private struct ConversationColumn: View {
    let store: StoreOf<SidebarFeature>

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
            // The column's head, ruled as the rail is: the conversations scroll under it here.
            Rectangle().fill(Color.turgaiInk.opacity(0.15)).frame(height: 1)
            ScrollView {
                // Grouped by nearness: a section's rows close together and its label close to them, the
                // sections far apart.
                LazyVStack(alignment: .leading, spacing: 0) {
                    if !store.entries.isEmpty || store.canStartConversation {
                        ConversationsHeading(space: store.shownSpace?.name, canStart: store.canStartConversation) {
                            store.send(.newConversationTapped)
                        }
                        .padding(.top, 16)
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(store.entries) { (entry: SidebarFeature.Entry) in
                                ConversationLine(entry: entry, hue: store.shownSpaceHue) {
                                    store.send(.selected(entry.id))
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
            // The shown space's tasks are followed while it's shown.
            .task(id: store.shownSpace?.id) {
                guard let space = store.shownSpace?.id else { return }
                await store.send(.tasks(.follow(space))).finish()
            }
            if let error = store.error {
                Text(error).font(.callout).foregroundStyle(Color.turgaiAccent).padding(12)
            }
        }
    }
}

/// A section's label in the shown space's column: a signpost in small capitals, tracked and muted,
/// so it doesn't compete with what it labels, whose weight says what's open or new.
struct SectionLabel: View {
    let title: String

    var body: some View {
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
                    .font(.body.weight(entry.standsOut ? .semibold : .regular))
                    .lineLimit(1)
                    .foregroundStyle(entry.isOpen ? hue.ink : Color.turgaiInk)
                Spacer(minLength: 0)
                if entry.unread {
                    Circle().fill(Color.turgaiAccent).frame(width: 7, height: 7)
                        .accessibilityLabel("New messages")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Inset, so its lean stays inside the column's edges.
            .background(
                StampBackground(color: entry.isOpen ? hue.color : .clear, lean: entry.lean)
                    .padding(.horizontal, 3)
            )
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

/// The shown space, heading its conversations: its name over what it is; for its admins, the name
/// is a menu that invites people to it, renames it, and archives it, or unarchives it.
private struct SpaceHeading: View {
    let name: String
    let archived: Bool
    /// How many people are in it, when there's more than one.
    let people: Int?
    /// What its menu offers, when its person is one of its admins: nothing otherwise.
    let menu: [SidebarFeature.SpaceMenuItem]
    let pick: (SidebarFeature.SpaceMenuItem) -> Void

    var body: some View {
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
    fileprivate static var panelGlyph: Font { .title3.weight(.regular) }
}
