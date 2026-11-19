/// One object's card, as `GET /api/v1/spaces/:space/objects/:object/card` gives it to someone who
/// may read the object: what it is, in Markdown, its data, its YAML and its Swift each in a block of
/// its own.
public struct ObjectCard: Codable, Hashable, Sendable {
    public let markdown: String

    public init(markdown: String) {
        self.markdown = markdown
    }
}
