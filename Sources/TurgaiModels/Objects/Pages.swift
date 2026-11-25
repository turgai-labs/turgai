import Mosaic

/// One of a space's pages, as `GET /api/v1/spaces/:space/pages` lists them: an object made in it
/// that conforms to `Page`.
public struct PageListing: Codable, Equatable, Sendable, Identifiable {
    /// The object it is.
    public let id: MadeObjectID
    /// What it's called.
    public let title: String
    public let summary: String?
    /// Its preview, when it gives one: what shows before it's opened.
    public let preview: Widget?

    public init(id: MadeObjectID, title: String, summary: String?, preview: Widget? = nil) {
        self.id = id
        self.title = title
        self.summary = summary
        self.preview = preview
    }
}

/// What a page shows now, as `GET /api/v1/spaces/:space/pages/:page` gives it: its widget, and
/// which layout that is, which a press names so one on a layout since replaced isn't taken.
public struct PageShown: Codable, Equatable, Sendable {
    public let widget: Widget
    public let version: Int

    public init(widget: Widget, version: Int) {
        self.widget = widget
        self.version = version
    }
}
