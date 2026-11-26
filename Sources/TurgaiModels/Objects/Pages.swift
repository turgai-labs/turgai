import Mosaic

/// One of a space's pages, as the connection lists them: an object made in it that conforms to
/// `Page`.
public struct PageListing: Codable, Equatable, Sendable, Identifiable {
    /// The object it is.
    public let id: MadeObjectID
    /// What it's called.
    public let title: String
    public let summary: String?
    /// Its preview, when it gives one: what shows before it's opened.
    public let preview: PagePreview?

    public init(id: MadeObjectID, title: String, summary: String?, preview: PagePreview? = nil) {
        self.id = id
        self.title = title
        self.summary = summary
        self.preview = preview
    }
}

/// What a page shows now, as the connection tells it: its widget, which layout that is, which a
/// press names so one on a layout since replaced isn't taken, and its own preview, when it gives
/// one.
public struct PageShown: Codable, Equatable, Sendable {
    public let widget: Widget
    public let version: Int
    /// What it shows before it's opened, when it gives that itself.
    public let preview: PagePreview?

    public init(widget: Widget, version: Int, preview: PagePreview? = nil) {
        self.widget = widget
        self.version = version
        self.preview = preview
    }
}

/// What a page shows before it's opened: its size, and the widget drawn at that size.
public enum PagePreview: Codable, Equatable, Sendable {
    /// A square, 160 by 160 points.
    case small(Widget)
    /// A rectangle as wide as two small ones side by side, 340 by 160 points.
    case medium(Widget)

    /// What it shows, whatever its size.
    public var widget: Widget {
        switch self {
        case .small(let widget), .medium(let widget): widget
        }
    }
}
