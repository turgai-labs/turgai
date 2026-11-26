import SwiftUI

/// A space's mark: its initial on a stamp of its color, or, outlined, in its deep shade inside the
/// stamp's outline.
package struct SpaceMark: View {
    let initial: String
    let hue: SpaceHue
    let lean: Lean
    let fill: StampFill

    package init(initial: String, hue: SpaceHue, lean: Lean, fill: StampFill) {
        self.initial = initial
        self.hue = hue
        self.lean = lean
        self.fill = fill
    }

    package var body: some View {
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

/// A conversation: its name, bolder with a dot when something's new in it; on a stamp of its space's
/// color, bolder, while it's open.
package struct ConversationLine: View {
    let entry: SidebarFeature.Entry
    /// Its space's color.
    let hue: SpaceHue
    let open: () -> Void

    package init(entry: SidebarFeature.Entry, hue: SpaceHue, open: @escaping () -> Void) {
        self.entry = entry
        self.hue = hue
        self.open = open
    }

    package var body: some View {
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

