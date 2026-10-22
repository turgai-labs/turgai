import Foundation
import Doppel
import Testing

@testable import TurgaiObjects

/// A page shown after another animates from it: each thing named by its place, the same thing in
/// the same place named the same on both.
@Suite("A website's page, as HTML")
struct PageViewTests {
    @Test("the morph keeps each thing by its id, a button by its label, the rest by place; only an id makes it slide")
    func thingsAreKeptByWhatTheyAre() {
        let layout = Layout.column([
            .text(id: "now playing", "Song", style: .title), .text("from Music"),
            .image(
                URL(string: "https://example.com/cover.jpg")!, description: "The album's cover", aspectRatio: .square,
                fit: .fill, width: 120),
            .row([.button("Play", kind: .prominent), .button("Next")], alignment: .top, spacing: 6),
        ])
        let html = PageDocument(layout: layout, version: 1).render()
        #expect(html.contains("Idiomorph.morph(page, html"))
        // An id given, a button's label, or else the place, as the morph keeps it.
        for name in ["item", "id-now_20_playing", "item-1", "item-2", "item-3", "label-Play", "label-Next"] {
            #expect(html.contains("id=\"\(name)\""), "\(name)")
        }
        // Only an id given makes it slide, by the edges its box lines it up by; the rest fade.
        #expect(html.components(separatedBy: "data-anchor=").count == 2)
        #expect(html.contains(#"id="id-now_20_playing" class="title primary" data-anchor="center top""#), "\(html)")
        let lined = LayoutView(
            layout: .column([
                .column([.text(id: "left", "Left")], alignment: .leading),
                .row([.button(id: "low", "Low")], alignment: .bottom),
            ]), version: 1
        ).render()
        #expect(lined.contains(#"id="id-left" class="body primary" data-anchor="leading top""#), "\(lined)")
        #expect(lined.contains(#"data-anchor="leading bottom""#), "\(lined)")
        #expect(html.contains(#"data-press="/press?label=Play&amp;page=1""#), "\(html)")
        #expect(html.contains(#"class="title primary""#))
        #expect(html.contains(#"class="prominent""#))
        #expect(html.contains(#"class="normal""#))
        #expect(html.contains(#"class="row top" style="gap: 6px"#))
        #expect(
            html.contains(
                #"src="https://example.com/cover.jpg" alt="The album's cover" loading="lazy" class="image fill" style="aspect-ratio: 1 / 1; width: 120px; "#
            ), "\(html)")
        #expect(html.contains(#"class="column center" style="gap: 12px"#))
    }
}

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
            ("file:///Users/me/secret.png", "a cover", PageProblem.notAWebAddress("file:///Users/me/secret.png")),
            ("cover.jpg", "a cover", .notAWebAddress("cover.jpg")),
            ("https://example.com/cover.jpg", " ", .noDescription),
        ])
    func picturesAreFromTheWeb(url: String, description: String, problem: PageProblem) {
        #expect(throws: problem) { try Layout(Page(items: [.image(url: url, description: description)])) }
    }
}
