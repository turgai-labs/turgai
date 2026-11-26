import ComposableArchitecture
import SwiftUI
import TurgaiModels

/// The sidebar's dialogs, over the whole window, so they show whatever's hidden: renaming a
/// conversation or a space, adding a space, inviting people, or every space to pick one; and
/// asking before a space is archived or a conversation deleted.
package struct SidebarDialogs: ViewModifier {
    @Bindable package var store: StoreOf<SidebarFeature>

    package init(store: StoreOf<SidebarFeature>) {
        self.store = store
    }

    package func body(content: Content) -> some View {
        // A step each, so each is type-checked on its own.
        let asking = content.alert($store.scope(\.$destination, action: \.destination).asking)
        let renaming = asking.sheet(
            item: $store.scope(\.$destination, action: \.destination).renaming
        ) { RenameSheet(store: $0, rename: { store.send(.renameConfirmed) }, cancel: dismiss) }
        let adding = renaming.sheet(
            item: $store.scope(\.$destination, action: \.destination).addingSpace
        ) { AddSpaceSheet(store: $0, cancel: dismiss) }
        let inviting = adding.sheet(
            item: $store.scope(\.$destination, action: \.destination).inviting
        ) { InviteSheet(store: $0, done: dismiss) }
        let choosing = inviting.sheet(
            item: $store.scope(\.$destination, action: \.destination).choosingSpace
        ) { SpacesSheet(store: $0, sections: store.spaceSections, pick: pick, submit: submit, done: dismiss) }
        let configuringBots = choosing.sheet(
            item: $store.scope(\.$destination, action: \.destination).bots
        ) { SpaceBotsSheet(store: $0, done: dismiss) }
        return configuringBots.sheet(
            item: $store.scope(\.$destination, action: \.destination).connections
        ) { SpaceConnectionsSheet(store: $0, done: dismiss) }
    }

    private func pick(_ space: SpaceID) {
        store.send(.spacePicked(space))
    }

    private func submit() {
        store.send(.spacesSubmitted)
    }

    private func dismiss() {
        store.send(.destination(.dismiss))
    }
}

/// A new name for a conversation or a space.
private struct RenameSheet: View {
    @Bindable package var store: StoreOf<SidebarFeature.Renaming>
    package let rename: () -> Void
    package let cancel: () -> Void

    package var body: some View {
        SheetFrame(store.title, width: 340, close: cancel) {
            TextField("Name", text: $store.name).onSubmit(rename)
        } buttons: {
            HStack {
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button("Rename", action: rename).keyboardShortcut(.defaultAction)
            }
        } actions: {
            Button("Rename", action: rename)
        }
    }
}

/// A space to add: a new one, by its name and then its first bot, or one joined, by an invite's
/// link; why it didn't work when it didn't.
private struct AddSpaceSheet: View {
    @Bindable package var store: StoreOf<SidebarFeature.AddingSpace>
    package let cancel: () -> Void

    package var body: some View {
        SheetFrame(store.title, width: 420, close: cancel) {
            if let bot = store.scope(\.bot, action: \.bot) {
                BotFields(store: bot)
            } else {
                NamingStep(store: store)
            }
            if let problem = store.problem {
                Text(problem).font(.callout).foregroundStyle(Color.turgaiAccent)
            }
        } buttons: {
            AddSpaceButtons(store: store, cancel: cancel)
        } actions: {
            AddSpaceActions(store: store)
        }
    }
}

/// A new space's name, or an invite's link to join one.
private struct NamingStep: View {
    @Bindable package var store: StoreOf<SidebarFeature.AddingSpace>

    package var body: some View {
        TextField("Name", text: $store.name).onSubmit { store.send(.nextTapped) }
        Divider()
        Text("Join a space").font(.headline)
        HStack {
            TextField("turgai://join/…", text: $store.link).typedVerbatim().onSubmit { store.send(.joinTapped) }
            Button("Join") { store.send(.joinTapped) }.disabled(!store.canJoin)
        }
    }
}

/// What the dialog's step can do: cancel, go on to the bot, back to the name, or make the space.
private struct AddSpaceButtons: View {
    package let store: StoreOf<SidebarFeature.AddingSpace>
    package let cancel: () -> Void

    package var body: some View {
        HStack {
            Spacer()
            Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
            if store.bot == nil {
                Button("Next") { store.send(.nextTapped) }.keyboardShortcut(.defaultAction).disabled(!store.canNext)
            } else {
                Button("Back") { store.send(.backTapped) }
                Button("Make Space") { store.send(.makeTapped) }
                    .keyboardShortcut(.defaultAction).disabled(!store.canMake)
            }
        }
    }
}

/// What the dialog's step does besides closing, in a phone's navigation bar: go on to the bot, or
/// back to the name and make the space.
private struct AddSpaceActions: View {
    package let store: StoreOf<SidebarFeature.AddingSpace>

    package var body: some View {
        if store.bot == nil {
            Button("Next") { store.send(.nextTapped) }.disabled(!store.canNext)
        } else {
            Button("Back") { store.send(.backTapped) }
            Button("Make Space") { store.send(.makeTapped) }.disabled(!store.canMake)
        }
    }
}

/// An invite to a space: its link, to copy and give someone, while it's made a moment, or why it
/// couldn't be.
private struct InviteSheet: View {
    package let store: StoreOf<SidebarFeature.Inviting>
    package let done: () -> Void

    package var body: some View {
        SheetFrame("Invite people to \(store.space.name)", width: 400, close: done) {
            Text("Whoever opens this link joins. It works once.")
                .foregroundStyle(Color.turgaiMuted)
            switch store.invite {
            case .making:
                ProgressView().controlSize(.small)
            case .made(let link):
                Text(link)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.turgaiInk.opacity(0.05), in: .rect(cornerRadius: 8))
            case .failed:
                Text("Couldn't make an invite. Try again.").font(.callout).foregroundStyle(Color.turgaiAccent)
            }
        } buttons: {
            HStack {
                Spacer()
                Button("Copy Link") { store.send(.copyTapped) }.disabled(!store.canCopy)
                Button("Done", action: done).keyboardShortcut(.defaultAction)
            }
        } actions: {
            Button("Copy Link") { store.send(.copyTapped) }.disabled(!store.canCopy)
        }
        .task { store.send(.appeared) }
    }
}

/// Every space the person is in, those in use, then those archived, to find one by its name and
/// show it.
private struct SpacesSheet: View {
    @Bindable package var store: StoreOf<SidebarFeature.ChoosingSpace>
    package let sections: [SidebarFeature.SpaceSection]
    package let pick: (SpaceID) -> Void
    /// Return in the search: the first found is shown.
    package let submit: () -> Void
    package let done: () -> Void

    package var body: some View {
        SheetFrame("Spaces", width: 360, close: done) {
            TextField("Find a space", text: $store.search).typedVerbatim().onSubmit(submit)
            SpaceListScroll {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(sections) { (section: SidebarFeature.SpaceSection) in
                        Text(section.status == .active ? "Active" : "Archived")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.turgaiMuted)
                            .padding(.top, 8)
                            .padding(.bottom, 2)
                        ForEach(section.choices) { (choice: SidebarFeature.SpaceChoice) in
                            SpaceListRow(choice: choice) { pick(choice.id) }
                        }
                    }
                    if sections.isEmpty {
                        Text("No space is called “\(store.search)”.")
                            .foregroundStyle(Color.turgaiMuted)
                            .padding(.top, 8)
                    }
                }
            }
        } buttons: {
            HStack {
                Spacer()
                Button("Done", action: done).keyboardShortcut(.cancelAction)
            }
        } actions: {
            EmptyView()
        }
    }
}

/// The Spaces list's own scroll on a Mac, 300 points high; on a phone the sheet scrolls it.
private struct SpaceListScroll<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        #if os(macOS)
            ScrollView { content }.frame(height: 300)
        #else
            content
        #endif
    }
}

/// A space in the Spaces list: its mark and its name.
private struct SpaceListRow: View {
    package let choice: SidebarFeature.SpaceChoice
    package let pick: () -> Void

    package var body: some View {
        Button(action: pick) {
            HStack(spacing: 10) {
                SpaceMark(initial: choice.initial, hue: choice.hue, lean: choice.lean, fill: choice.fill)
                Text(choice.space.name).lineLimit(1).foregroundStyle(Color.turgaiInk)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 3)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}
