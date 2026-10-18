import AnyLanguageModel
import Foundation
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
    /// Words to read, in a style and colour.
    case text(id: String? = nil, words: String, style: TextStyle = .body, color: TextColor = .primary)
    /// A button. Pressing it announces ButtonPressed with its label.
    case button(id: String? = nil, label: String, kind: ButtonKind = .normal)
    /// A picture from the web, at an http or https `url`, `description` saying what it shows, `width` points wide, or as wide as there's room for.
    case image(id: String? = nil, url: String, description: String, aspectRatio: AspectRatio = .original, fit: ImageFit = .fit, width: Double? = nil)
    /// Things side by side, left to right, aligned, `spacing` points apart.
    case row(id: String? = nil, items: [Inner], alignment: RowAlignment = .center, spacing: Double = 12)
    /// Things one under another, top to bottom, aligned, `spacing` points apart.
    case column(id: String? = nil, items: [Inner], alignment: ColumnAlignment = .center, spacing: Double = 12)
}

/// Something inside a row or a column.
@Generable(description: "Something inside a row or a column.")
@Describable
public enum Inner: Codable, Sendable, Equatable {
    /// Words to read, in a style and colour.
    case text(id: String? = nil, words: String, style: TextStyle = .body, color: TextColor = .primary)
    /// A button. Pressing it announces ButtonPressed with its label.
    case button(id: String? = nil, label: String, kind: ButtonKind = .normal)
    /// A picture from the web, at an http or https `url`, `description` saying what it shows, `width` points wide, or as wide as there's room for.
    case image(id: String? = nil, url: String, description: String, aspectRatio: AspectRatio = .original, fit: ImageFit = .fit, width: Double? = nil)
    /// Things side by side, left to right, aligned, `spacing` points apart.
    case row(id: String? = nil, items: [Leaf], alignment: RowAlignment = .center, spacing: Double = 12)
    /// Things one under another, top to bottom, aligned, `spacing` points apart.
    case column(id: String? = nil, items: [Leaf], alignment: ColumnAlignment = .center, spacing: Double = 12)
}

/// Words or a button, at the deepest level.
@Generable(description: "Words or a button.")
@Describable
public enum Leaf: Codable, Sendable, Equatable {
    /// Words to read, in a style and colour.
    case text(id: String? = nil, words: String, style: TextStyle = .body, color: TextColor = .primary)
    /// A button. Pressing it announces ButtonPressed with its label.
    case button(id: String? = nil, label: String, kind: ButtonKind = .normal)
    /// A picture from the web, at an http or https `url`, `description` saying what it shows, `width` points wide, or as wide as there's room for.
    case image(id: String? = nil, url: String, description: String, aspectRatio: AspectRatio = .original, fit: ImageFit = .fit, width: Double? = nil)
}

// Each thing's `id`, when it's given, is what it is on the page: the same thing on the page
// before and after, wherever it is, as SwiftUI's `id` is. Without one, a button is its label,
// and anything else its place.

/// How things side by side line up.
@Generable(description: "How things side by side line up.")
@Describable
public enum RowAlignment: String, Codable, Sendable, Equatable {
    /// Along their tops.
    case top
    /// On their centres.
    case center
    /// Along their bottoms.
    case bottom
}

/// How things one under another line up.
@Generable(description: "How things one under another line up.")
@Describable
public enum ColumnAlignment: String, Codable, Sendable, Equatable {
    /// Along their leading edges.
    case leading
    /// On their centres.
    case center
    /// Along their trailing edges.
    case trailing
}

/// A picture's shape, width to height.
@Generable(description: "A picture's shape, width to height.")
@Describable
public enum AspectRatio: String, Codable, Sendable, Equatable {
    /// As the picture is.
    case original
    /// 1:1.
    case square
    /// 4:3, wider than high.
    case landscape
    /// 16:9, much wider than high.
    case wide
    /// 3:4, higher than wide.
    case portrait
}

/// How a picture fills its shape.
@Generable(description: "How a picture fills its shape.")
@Describable
public enum ImageFit: String, Codable, Sendable, Equatable {
    /// All of it shows, inside the shape.
    case fit
    /// It covers the shape, cut at the edges.
    case fill
}

/// How words look: what they are on the page.
@Generable(description: "How words look: what they are on the page.")
@Describable
public enum TextStyle: String, Codable, Sendable, Equatable {
    /// The page's title, largest.
    case title
    /// A heading over what follows.
    case heading
    /// Ordinary words.
    case body
    /// Small words beside something else.
    case caption
    /// Words that stand out among others.
    case emphasis
}

/// The colour of words: what they mean.
@Generable(description: "The colour of words: what they mean.")
@Describable
public enum TextColor: String, Codable, Sendable, Equatable {
    /// Ordinary words.
    case primary
    /// Words that matter less.
    case secondary
    /// Words to notice.
    case accent
    /// Something that went well.
    case positive
    /// Something to be careful of.
    case warning
    /// Something that went wrong.
    case negative
}

/// What a button does, as it looks.
@Generable(description: "What a button does, as it looks.")
@Describable
public enum ButtonKind: String, Codable, Sendable, Equatable {
    /// An ordinary button.
    case normal
    /// The button most pressed, which stands out.
    case prominent
    /// A button that removes or ends something.
    case destructive
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
    case row(id: String? = nil, [Layout], alignment: RowAlignment = .center, spacing: Double = 12)
    case column(id: String? = nil, [Layout], alignment: ColumnAlignment = .center, spacing: Double = 12)
    case text(id: String? = nil, String, style: TextStyle = .body, color: TextColor = .primary)
    case button(id: String? = nil, String, kind: ButtonKind = .normal)
    case image(id: String? = nil, URL, description: String, aspectRatio: AspectRatio = .original, fit: ImageFit = .fit, width: Double? = nil)

    init(_ page: Page) throws {
        self = .column(try page.items.map(Layout.init))
        var labels: Set<String> = []
        for label in buttons where !labels.insert(label).inserted {
            throw PageProblem.sameLabel(label)
        }
        var ids: Set<String> = []
        for id in self.ids where !ids.insert(id).inserted {
            throw PageProblem.sameID(id)
        }
    }

    private init(_ item: Item) throws {
        switch item {
        case .text(let id, let words, let style, let color): self = try .said(words, style, color, id)
        case .button(let id, let label, let kind): self = try .labelled(label, kind, id)
        case .image(let id, let url, let description, let aspectRatio, let fit, let width):
            self = try .pictured(id, url, description, aspectRatio, fit, width)
        case .row(let id, let items, let alignment, let spacing): self = .row(id: try Self.identified(id), try items.map(Layout.init), alignment: alignment, spacing: try Self.spaced(spacing))
        case .column(let id, let items, let alignment, let spacing): self = .column(id: try Self.identified(id), try items.map(Layout.init), alignment: alignment, spacing: try Self.spaced(spacing))
        }
    }

    private init(_ item: Inner) throws {
        switch item {
        case .text(let id, let words, let style, let color): self = try .said(words, style, color, id)
        case .button(let id, let label, let kind): self = try .labelled(label, kind, id)
        case .image(let id, let url, let description, let aspectRatio, let fit, let width):
            self = try .pictured(id, url, description, aspectRatio, fit, width)
        case .row(let id, let items, let alignment, let spacing): self = .row(id: try Self.identified(id), try items.map(Layout.init), alignment: alignment, spacing: try Self.spaced(spacing))
        case .column(let id, let items, let alignment, let spacing): self = .column(id: try Self.identified(id), try items.map(Layout.init), alignment: alignment, spacing: try Self.spaced(spacing))
        }
    }

    private init(_ item: Leaf) throws {
        switch item {
        case .text(let id, let words, let style, let color): self = try .said(words, style, color, id)
        case .button(let id, let label, let kind): self = try .labelled(label, kind, id)
        case .image(let id, let url, let description, let aspectRatio, let fit, let width):
            self = try .pictured(id, url, description, aspectRatio, fit, width)
        }
    }

    /// Words, which have something to say.
    private static func said(_ words: String, _ style: TextStyle, _ color: TextColor, _ id: String?) throws(PageProblem) -> Layout {
        let words = words.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { throw .noText }
        return .text(id: try identified(id), words, style: style, color: color)
    }

    /// A picture, from the web, which says what it shows.
    private static func pictured(
        _ id: String?, _ url: String, _ description: String, _ aspectRatio: AspectRatio, _ fit: ImageFit, _ width: Double?
    ) throws(PageProblem) -> Layout {
        let address = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = URL(string: address), ["http", "https"].contains(parsed.scheme?.lowercased() ?? ""), parsed.host != nil else {
            throw .notAWebAddress(address)
        }
        let description = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !description.isEmpty else { throw .noDescription }
        if let width { guard width > 0, width.isFinite else { throw .noWidth(width) } }
        return .image(id: try identified(id), parsed, description: description, aspectRatio: aspectRatio, fit: fit, width: width)
    }

    /// How far apart things are, in points: never less than touching.
    private static func spaced(_ spacing: Double) throws(PageProblem) -> Double {
        guard spacing >= 0, spacing.isFinite else { throw .negativeSpacing(spacing) }
        return spacing
    }

    /// An id, which says something: one that's only spaces is no id.
    private static func identified(_ id: String?) throws(PageProblem) -> String? {
        guard let id else { return nil }
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw .noID }
        return trimmed
    }

    /// A button, which has a label.
    private static func labelled(_ label: String, _ kind: ButtonKind, _ id: String?) throws(PageProblem) -> Layout {
        let label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { throw .noLabel }
        return .button(id: try identified(id), label, kind: kind)
    }

    /// Every button's label, in page order.
    var buttons: [String] {
        switch self {
        case .row(_, let items, _, _), .column(_, let items, _, _): items.flatMap(\.buttons)
        case .text, .image: []
        case .button(_, let label, _): [label]
        }
    }

    /// Every id given, in page order.
    var ids: [String] {
        switch self {
        case .row(let id, let items, _, _), .column(let id, let items, _, _): [id].compactMap { $0 } + items.flatMap(\.ids)
        case .text(let id, _, _, _), .button(let id, _, _), .image(let id, _, _, _, _, _): [id].compactMap { $0 }
        }
    }
}

/// Why a page can't be shown.
public enum PageProblem: Error, Codable, Equatable, Sendable, CustomStringConvertible {
    case noText
    case noLabel
    case sameLabel(String)
    case noID
    case negativeSpacing(Double)
    case notAWebAddress(String)
    case noDescription
    case noWidth(Double)
    case sameID(String)

    public var description: String {
        switch self {
        case .noText: "A text has no words: give it `words`."
        case .noLabel: "A button has no label: give it `label`."
        case .sameLabel(let label): "Two buttons say `\(label)`: each button needs a label of its own."
        case .noID: "An id is empty: give it one, or leave `id` out."
        case .negativeSpacing(let spacing): "A spacing is \(spacing): it's points apart, from 0."
        case .notAWebAddress(let url): "`\(url)` isn't a web address: a picture's url starts with https:// or http://."
        case .noDescription: "A picture has no description: say what it shows, in `description`."
        case .noWidth(let width): "A picture's width is \(width): it's points wide, more than 0, or leave `width` out."
        case .sameID(let id): "Two things have the id `\(id)`: each id is one thing's."
        }
    }
}
