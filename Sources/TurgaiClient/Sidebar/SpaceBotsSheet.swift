import ComposableArchitecture
import Foundation
import SwiftUI
import TurgaiModels

/// A space's bots, each with what can be done to it, or the bot form while one's written.
package struct SpaceBotsSheet: View {
    package let store: StoreOf<SidebarFeature.SpaceBots>
    package let done: () -> Void

    package var body: some View {
        SheetFrame(store.title, width: 440, close: done) {
            if let form = store.scope(\.form, action: \.form) {
                BotFields(store: form)
            } else {
                ForEach(store.bots) { bot in SpaceBotRow(store: store, bot: bot) }
            }
            if let problem = store.problem {
                Text(problem).font(.callout).foregroundStyle(Color.turgaiAccent)
            }
        } buttons: {
            SpaceBotsButtons(store: store, done: done)
        } actions: {
            SpaceBotsActions(store: store)
        }
        .task { store.send(.shown) }
    }
}

/// One of a space's bots: what it's called and runs on, and its menu.
private struct SpaceBotRow: View {
    package let store: StoreOf<SidebarFeature.SpaceBots>
    package let bot: SpaceBot

    package var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(bot.isMain ? "\(bot.name) · main" : bot.name)
                Text("\(bot.provider.title) · \(bot.model)").font(.callout).foregroundStyle(Color.turgaiMuted)
            }
            Spacer()
            Menu("Actions") {
                Button("Change…") { store.send(.changeTapped(bot)) }
                Button("Make Main") { store.send(.mainTapped(bot)) }.disabled(bot.isMain)
                Button("Remove", role: .destructive) { store.send(.removeTapped(bot)) }.disabled(bot.isMain)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }
}

/// What the sheet can do: add a bot, or, while one's written, cancel or save it; and close.
/// What the sheet does besides closing, in a phone's navigation bar: add a bot; or, while one's
/// written, leave it or save it.
private struct SpaceBotsActions: View {
    package let store: StoreOf<SidebarFeature.SpaceBots>

    package var body: some View {
        if store.form == nil {
            Button("Add Bot…") { store.send(.addTapped) }
        } else {
            Button("Cancel") { store.send(.formCancelled) }
            Button("Save") { store.send(.saveTapped) }.disabled(!store.canSave)
        }
    }
}

private struct SpaceBotsButtons: View {
    package let store: StoreOf<SidebarFeature.SpaceBots>
    package let done: () -> Void

    package var body: some View {
        HStack {
            if store.form == nil {
                Button("Add Bot…") { store.send(.addTapped) }
                Spacer()
                Button("Done", action: done).keyboardShortcut(.defaultAction)
            } else {
                Spacer()
                Button("Cancel") { store.send(.formCancelled) }.keyboardShortcut(.cancelAction)
                Button("Save") { store.send(.saveTapped) }.keyboardShortcut(.defaultAction).disabled(!store.canSave)
            }
        }
    }
}
