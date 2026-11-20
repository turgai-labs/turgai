import Doppel
import Foundation
import Mosaic
import Testing

@testable import TurgaiObjects

/// A page's styles as the writer is given them: Swift's own declarations, each optional value
/// `nil` when it's left out, so a page written before them still is one.
@Suite("A page's styles, in the spec")
struct PageStyleSpecTests {
    @Test("the spec declares the styles, and code with them and without them is Swift")
    func stylesAreDeclaredAndOptional() {
        let spec = Uses.declarations(of: [Page.jsonSchema])
        #expect(
            spec.contains(
                "case text(id: String? = nil, words: String, style: TextStyle = .body, color: TextColor = .primary)"),
            "\(spec)")
        #expect(spec.contains("case button(id: String? = nil, label: String, kind: ButtonKind = .normal)"))
        #expect(
            spec.contains(
                "case column(id: String? = nil, items: [Inner], alignment: ColumnAlignment = .center, spacing: Double = 12)"
            ))
        #expect(spec.contains("enum TextStyle"))
        #expect(
            spec.contains(
                "case image(id: String? = nil, url: String, description: String, aspectRatio: AspectRatio = .original, fit: ImageFit = .fit, width: Double? = nil)"
            ),
            "\(spec)")
        let code = """
            actor Shown {
                func page() -> Page {
                    Page(items: [
                        .text(id: "song", words: "Song", style: .title),
                        .row(items: [.button(label: "Play", kind: .prominent), .button(label: "Next")]),
                        .text(words: "from Music", color: .secondary),
                        Item.text(words: "plain"),
                        .image(url: "https://example.com/a.png", description: "A cover", aspectRatio: .square),
                    ])
                }
            }
            """
        let problems = SwiftCheck.problems(
            in: "Object.swift", of: [.init(name: "Objects.swift", code: spec), .init(name: "Object.swift", code: code)])
        #expect(problems.isEmpty, "\(problems)")
    }
}

extension PageStyleSpecTests {
    @Test("a page's schema, as a model is given it, has the styles")
    func schemaHasTheStyles() throws {
        let schema = String(decoding: try JSONEncoder().encode(Page.generationSchema), as: UTF8.self)
        #expect(schema.contains("TextStyle"), "\(schema)")
        #expect(schema.contains("prominent"))
    }
}

extension PageStyleSpecTests {
    @Test(
        "a picture is from the web, and says what it shows",
        arguments: [
            (
                "file:///Users/me/secret.png", "a cover",
                PageProblem.widget(.notAWebAddress("file:///Users/me/secret.png"))
            ),
            ("cover.jpg", "a cover", .widget(.notAWebAddress("cover.jpg"))),
            ("https://example.com/cover.jpg", " ", .widget(.noDescription)),
        ])
    func picturesAreFromTheWeb(url: String, description: String, problem: PageProblem) {
        #expect(throws: problem) { try Widget(Page(items: [.image(url: url, description: description)])) }
    }
}

extension PageStyleSpecTests {
    @Test("a page's items are named by their id, or by their kind and place, and its buttons by their labels")
    func itemsAreNamed() throws {
        let widget = try Widget(
            Page(items: [
                .text(id: "title", words: "Menu"),
                .row(items: [.button(label: "Order"), .text(words: "or")]),
            ]))
        #expect(widget.widget(at: try #require(PiecePath("page/title"))) != nil)
        #expect(
            widget.widget(at: try #require(PiecePath("page/%23row-2/%23button-1")))
                == .button(try Button("#button-1", "Order")))
        #expect(throws: PageProblem.sameLabel("Order")) {
            try Widget(Page(items: [.button(label: "Order"), .row(items: [.button(label: "Order ")])]))
        }
    }
}
