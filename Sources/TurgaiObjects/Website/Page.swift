import AnyLanguageModel
import DiscoverableActors

// A page nests three levels deep, each level its own type: a recursive `@Generable` type
// overflows the stack building its schema, as its schema asks for its own again. Once
// AnyLanguageModel refers to a type it's already building, the levels become one `Item`.

/// A web page: what it shows, top to bottom.
@Generable(description: "A web page: what it shows, top to bottom.")
@Describable
public struct Page: Codable, Sendable, Equatable {
    /// What it shows, top to bottom.
    @Guide(description: "What it shows, top to bottom.")
    public var items: [Item]
}

/// Something a page shows.
@Generable(description: "Something a page shows.")
@Describable
public enum Item: Codable, Sendable, Equatable {
    /// Words to read.
    case text(words: String)
    /// A button. Pressing it announces ButtonPressed with its label.
    case button(label: String)
    /// Things side by side, left to right.
    case row(items: [Inner])
    /// Things one under another, top to bottom.
    case column(items: [Inner])
}

/// Something inside a row or a column.
@Generable(description: "Something inside a row or a column.")
@Describable
public enum Inner: Codable, Sendable, Equatable {
    /// Words to read.
    case text(words: String)
    /// A button. Pressing it announces ButtonPressed with its label.
    case button(label: String)
    /// Things side by side, left to right.
    case row(items: [Leaf])
    /// Things one under another, top to bottom.
    case column(items: [Leaf])
}

/// Words or a button, at the deepest level.
@Generable(description: "Words or a button.")
@Describable
public enum Leaf: Codable, Sendable, Equatable {
    /// Words to read.
    case text(words: String)
    /// A button. Pressing it announces ButtonPressed with its label.
    case button(label: String)
}

extension Page {
    /// The page a website starts with: every kind of item, nested as deep as items go, so the
    /// page it shows is always one to change.
    static let start = Page(items: [
        .text(words: "A new website"),
        .row(items: [
            .column(items: [.text(words: "First column"), .button(label: "First")]),
            .column(items: [.text(words: "Second column"), .button(label: "Second")]),
        ]),
        .button(label: "Third"),
    ])
}

// MARK: Layout

/// A page as it's shown: any depth, every text and label there, and each button's label its own.
/// Read from a ``Page`` by ``init(_:)``, so nothing past it checks a page again.
indirect enum Layout: Equatable, Sendable {
    case row([Layout])
    case column([Layout])
    case text(String)
    case button(String)

    init(_ page: Page) throws {
        self = .column(try page.items.map(Layout.init))
        var labels: Set<String> = []
        for label in buttons where !labels.insert(label).inserted {
            throw PageProblem.sameLabel(label)
        }
    }

    private init(_ item: Item) throws {
        switch item {
        case .text(let words): self = try .said(words)
        case .button(let label): self = try .labelled(label)
        case .row(let items): self = .row(try items.map(Layout.init))
        case .column(let items): self = .column(try items.map(Layout.init))
        }
    }

    private init(_ item: Inner) throws {
        switch item {
        case .text(let words): self = try .said(words)
        case .button(let label): self = try .labelled(label)
        case .row(let items): self = .row(try items.map(Layout.init))
        case .column(let items): self = .column(try items.map(Layout.init))
        }
    }

    private init(_ item: Leaf) throws {
        switch item {
        case .text(let words): self = try .said(words)
        case .button(let label): self = try .labelled(label)
        }
    }

    /// Words, which have something to say.
    private static func said(_ words: String) throws(PageProblem) -> Layout {
        let words = words.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { throw .noText }
        return .text(words)
    }

    /// A button, which has a label.
    private static func labelled(_ label: String) throws(PageProblem) -> Layout {
        let label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { throw .noLabel }
        return .button(label)
    }

    /// Every button's label, in page order.
    var buttons: [String] {
        switch self {
        case .row(let items), .column(let items): items.flatMap(\.buttons)
        case .text: []
        case .button(let label): [label]
        }
    }
}

/// Why a page can't be shown.
public enum PageProblem: Error, Codable, Equatable, Sendable, CustomStringConvertible {
    case noText
    case noLabel
    case sameLabel(String)

    public var description: String {
        switch self {
        case .noText: "A text has no words: give it `words`."
        case .noLabel: "A button has no label: give it `label`."
        case .sameLabel(let label): "Two buttons say `\(label)`: each button needs a label of its own."
        }
    }
}
