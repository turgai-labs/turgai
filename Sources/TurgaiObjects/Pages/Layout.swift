import AnyLanguageModel
import DiscoverableActors
import Foundation
import Mosaic

// A layout nests three levels deep, each level its own type: a recursive `@Generable` type
// overflows the stack building its schema, as its schema asks for its own again. Once
// AnyLanguageModel refers to a type it's already building, the levels become one `Item`.

/// A page's layout: what it shows, top to bottom.
@Generable(description: "A page's layout: what it shows, top to bottom.")
@Describable
public struct Layout: Codable, Sendable, Equatable {
    /// What it shows, top to bottom.
    @Guide(description: "What it shows, top to bottom.")
    public var items: [Item]
}

/// Something a layout shows.
@Generable(description: "Something a layout shows.")
@Describable
public enum Item: Codable, Sendable, Equatable {
    /// Words to read, in a style and colour.
    case text(id: String? = nil, words: String, style: TextStyle = .body, color: TextColor = .primary)
    /// A button. Pressing it announces ButtonPressed with its label.
    case button(id: String? = nil, label: String, kind: ButtonKind = .normal)
    /// A picture from the web, at an http or https `url`, `description` saying what it shows, `width` points wide, or as wide as there's room for.
    case image(
        id: String? = nil, url: String, description: String, aspectRatio: AspectRatio = .original, fit: ImageFit = .fit,
        width: Double? = nil)
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
    case image(
        id: String? = nil, url: String, description: String, aspectRatio: AspectRatio = .original, fit: ImageFit = .fit,
        width: Double? = nil)
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
    case image(
        id: String? = nil, url: String, description: String, aspectRatio: AspectRatio = .original, fit: ImageFit = .fit,
        width: Double? = nil)
}

// Each thing's `id`, when it's given, is what it is on the layout: the same thing on the layout
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

/// How words look: what they are on the layout.
@Generable(description: "How words look: what they are on the layout.")
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

extension Layout {
    /// The layout a page starts with: every kind of item, nested as deep as items go, so the
    /// layout it shows is always one to change.
    static let start = Layout(items: [
        .text(words: "A new page"),
        .row(items: [
            .column(items: [.text(words: "First column"), .button(label: "First")]),
            .column(items: [.text(words: "Second column"), .button(label: "Second")]),
        ]),
        .button(label: "Third"),
    ])
}

// MARK: As a widget

// What a model writes is a layout, three levels deep, in the words its schema has; what's shown is
// Mosaic's widget, any depth, every piece with an id. A piece the layout gives no id is named by its
// kind and place, which no written id starts like.

extension Widget {
    /// `layout` as it's shown: a column of its items, each button's label its own, since a press is
    /// told to the page by its label.
    public init(_ layout: Layout) throws(LayoutProblem) {
        do {
            self = .stack(try Stack("page", .vertical(), try Self.pieces(layout.items, Self.init)))
        } catch {
            throw .widget(error)
        }
        var labels: Set<String> = []
        for label in buttons where !labels.insert(label).inserted { throw .sameLabel(label) }
    }

    private init(_ item: Item, at index: Int) throws(WidgetProblem) {
        switch item {
        case .text(let id, let words, let style, let color):
            self = .text(try Text(Self.named(id, "text", index), words, style: .init(style), color: .init(color)))
        case .button(let id, let label, let kind):
            self = .button(try Button(Self.named(id, "button", index), label, kind: .init(kind)))
        case .image(let id, let url, let description, let aspectRatio, let fit, let width):
            self = .image(
                try Image(
                    Self.named(id, "image", index), address: url, description: description,
                    aspectRatio: .init(aspectRatio), fit: .init(fit), width: width))
        case .row(let id, let items, let alignment, let spacing):
            self = .stack(
                try Stack(
                    Self.named(id, "row", index), .horizontal(alignment: .init(alignment)),
                    try Self.pieces(items, Self.init), spacing: spacing))
        case .column(let id, let items, let alignment, let spacing):
            self = .stack(
                try Stack(
                    Self.named(id, "column", index), .vertical(alignment: .init(alignment)),
                    try Self.pieces(items, Self.init), spacing: spacing))
        }
    }

    private init(_ item: Inner, at index: Int) throws(WidgetProblem) {
        switch item {
        case .text(let id, let words, let style, let color):
            self = .text(try Text(Self.named(id, "text", index), words, style: .init(style), color: .init(color)))
        case .button(let id, let label, let kind):
            self = .button(try Button(Self.named(id, "button", index), label, kind: .init(kind)))
        case .image(let id, let url, let description, let aspectRatio, let fit, let width):
            self = .image(
                try Image(
                    Self.named(id, "image", index), address: url, description: description,
                    aspectRatio: .init(aspectRatio), fit: .init(fit), width: width))
        case .row(let id, let items, let alignment, let spacing):
            self = .stack(
                try Stack(
                    Self.named(id, "row", index), .horizontal(alignment: .init(alignment)),
                    try Self.pieces(items, Self.init), spacing: spacing))
        case .column(let id, let items, let alignment, let spacing):
            self = .stack(
                try Stack(
                    Self.named(id, "column", index), .vertical(alignment: .init(alignment)),
                    try Self.pieces(items, Self.init), spacing: spacing))
        }
    }

    private init(_ item: Leaf, at index: Int) throws(WidgetProblem) {
        switch item {
        case .text(let id, let words, let style, let color):
            self = .text(try Text(Self.named(id, "text", index), words, style: .init(style), color: .init(color)))
        case .button(let id, let label, let kind):
            self = .button(try Button(Self.named(id, "button", index), label, kind: .init(kind)))
        case .image(let id, let url, let description, let aspectRatio, let fit, let width):
            self = .image(
                try Image(
                    Self.named(id, "image", index), address: url, description: description,
                    aspectRatio: .init(aspectRatio), fit: .init(fit), width: width))
        }
    }

    /// Items, each made a piece knowing its place among them.
    private static func pieces<Item>(
        _ items: [Item], _ piece: (Item, Int) throws(WidgetProblem) -> Widget
    ) throws(WidgetProblem) -> [Widget] {
        var pieces: [Widget] = []
        for (index, item) in items.enumerated() { pieces.append(try piece(item, index)) }
        return pieces
    }

    /// The id written, or else its kind and place: `#text-2` for the second item, a text.
    private static func named(_ id: String?, _ kind: String, _ index: Int) -> String {
        id ?? "#\(kind)-\(index + 1)"
    }

    /// Every button's label, in order.
    var buttons: [String] {
        switch self {
        case .button(let button): [button.label.rawValue]
        default: children.flatMap(\.buttons)
        }
    }
}

/// Why a layout can't be shown.
public enum LayoutProblem: Error, Codable, Equatable, Sendable, CustomStringConvertible {
    /// It isn't a whole widget.
    case widget(WidgetProblem)
    /// Two of its buttons say the same.
    case sameLabel(String)

    public var description: String {
        switch self {
        case .widget(let problem): problem.description
        case .sameLabel(let label): "Two buttons say `\(label)`: each button needs a label of its own."
        }
    }
}

extension Mosaic.VerticalAlignment {
    init(_ alignment: RowAlignment) {
        switch alignment {
        case .top: self = .top
        case .center: self = .center
        case .bottom: self = .bottom
        }
    }
}

extension Mosaic.HorizontalAlignment {
    init(_ alignment: ColumnAlignment) {
        switch alignment {
        case .leading: self = .leading
        case .center: self = .center
        case .trailing: self = .trailing
        }
    }
}

extension Mosaic.AspectRatio {
    init(_ ratio: AspectRatio) {
        switch ratio {
        case .original: self = .original
        case .square: self = .square
        case .landscape: self = .landscape
        case .wide: self = .wide
        case .portrait: self = .portrait
        }
    }
}

extension Mosaic.ImageFit {
    init(_ fit: ImageFit) {
        switch fit {
        case .fit: self = .fit
        case .fill: self = .fill
        }
    }
}

extension Mosaic.TextStyle {
    init(_ style: TextStyle) {
        switch style {
        case .title: self = .title
        case .heading: self = .heading
        case .body: self = .body
        case .caption: self = .caption
        case .emphasis: self = .emphasis
        }
    }
}

extension Mosaic.TextColor {
    init(_ color: TextColor) {
        switch color {
        case .primary: self = .primary
        case .secondary: self = .secondary
        case .accent: self = .accent
        case .positive: self = .positive
        case .warning: self = .warning
        case .negative: self = .negative
        }
    }
}

extension Mosaic.ButtonKind {
    init(_ kind: ButtonKind) {
        switch kind {
        case .normal: self = .normal
        case .prominent: self = .prominent
        case .destructive: self = .destructive
        }
    }
}
