import ComposableArchitecture
import SwiftUI
import TurgaiClient
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
    let pages: StoreOf<PagesFeature>
    let openPage: (PageAddress) -> Void
    let openPageInWindow: (PageAddress) -> Void
    let toggle: () -> Void

    /// How much of the window's top left the traffic lights take, with room after them.
    private static let trafficLightsWidth: CGFloat = 86
    static let buttonSize: CGFloat = 32
    private static let shape = RoundedRectangle(cornerRadius: 16)

    var body: some View {
        ZStack(alignment: .topLeading) {
            if isShown {
                SidebarView(store: store, pages: pages, openPage: openPage, openPageInWindow: openPageInWindow)
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
/// that hides it; then the spaces, and the shown space's conversations or pages.
private struct SidebarView: View {
    let store: StoreOf<SidebarFeature>
    let pages: StoreOf<PagesFeature>
    let openPage: (PageAddress) -> Void
    let openPageInWindow: (PageAddress) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: SidebarGlass.buttonSize)
            SpacesPanel(
                store: store, pages: pages, openConversation: { store.send(.selected($0)) }, openPage: openPage,
                openPageInWindow: openPageInWindow)
        }
    }
}
