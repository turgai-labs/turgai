import DiscoverableActors

/// A page's preview: its size, and what it shows drawn at that size.
@Describable
public enum Preview: Codable, Sendable, Equatable {
    /// A square, 160 by 160 points.
    case small(Layout)
    /// A rectangle as wide as two small ones side by side, 340 by 160 points.
    case medium(Layout)

    /// What it shows, whatever its size.
    public var layout: Layout {
        switch self {
        case .small(let layout), .medium(let layout): layout
        }
    }
}
