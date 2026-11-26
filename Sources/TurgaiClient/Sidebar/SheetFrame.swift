import SwiftUI

/// A sheet's frame, as each platform gives one. On a phone: a navigation bar with its title, ✕ to
/// close it, and what it does besides, its content the sheet's width, scrolling. On a Mac: its title
/// over its content, its buttons under it, as a dialog has them, at `width`.
package struct SheetFrame<Content: View, Buttons: View, Actions: View>: View {
    let title: String
    let width: CGFloat
    let close: () -> Void
    let content: Content
    /// Its buttons, under it, on a Mac.
    let buttons: Buttons
    /// What it does besides closing, in a phone's navigation bar.
    let actions: Actions

    package init(
        _ title: String, width: CGFloat, close: @escaping () -> Void, @ViewBuilder content: () -> Content,
        @ViewBuilder buttons: () -> Buttons, @ViewBuilder actions: () -> Actions
    ) {
        self.title = title
        self.width = width
        self.close = close
        self.content = content()
        self.buttons = buttons()
        self.actions = actions()
    }

    package var body: some View {
        #if os(iOS)
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) { content }
                        .padding(20)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollDismissesKeyboard(.interactively)
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button(role: .close, action: close) }
                    ToolbarItemGroup(placement: .confirmationAction) { actions }
                }
            }
        #else
            VStack(alignment: .leading, spacing: 14) {
                Text(title).font(.headline)
                content
                buttons
            }
            .padding(20)
            .frame(width: width)
        #endif
    }
}
