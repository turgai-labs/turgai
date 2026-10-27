/// One object, as `GET /api/v1/objects` lists it to the signed-in account: what it is, what it
/// takes, and the node it lives on. Only what the account may read is listed.
public struct ObjectListing: Codable, Hashable, Sendable {
    /// Its actor's id, the same while it lives.
    public let id: String
    /// What it's called: its name, or its type for the one of its kind.
    public let title: String
    public let summary: String?
    /// Each action with its arguments, such as `play(query)`.
    public let actions: [String]
    /// What it announces, such as `RefundRequested`.
    public let events: [String]
    /// The node it lives on, such as `127.0.0.1:52034`.
    public let node: String

    public init(id: String, title: String, summary: String?, actions: [String], events: [String], node: String) {
        self.id = id
        self.title = title
        self.summary = summary
        self.actions = actions
        self.events = events
        self.node = node
    }
}
