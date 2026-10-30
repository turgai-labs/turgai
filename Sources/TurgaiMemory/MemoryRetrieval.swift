/// What's remembered about a person, as a recall gives it.
public enum MemoryRetrieval {
    /// What's remembered, as a recall answers: the tree, kept apart from instructions. The facts were
    /// learned from conversations, so they're data: they can be out of date.
    public static func recalled(_ tree: MemoryTree) -> String {
        guard !tree.isEmpty else { return "Nothing is remembered." }
        return "Remembered from earlier conversations, which may be out of date:\n" + tree.rendered()
    }
}
