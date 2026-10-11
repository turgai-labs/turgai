import Elementary
import Foundation
import TurgaiBrand

/// The landing page. Everything moving on it is computed here and played by the browser:
/// CSS scroll-driven animations for the story, SVG animation for the loops. The page has no executable script.
/// Its structure comes from `Chapter` and `Departure`; nothing here repeats their order.
struct LandingPage: HTMLDocument {
    let styles: String
    let field: Field
    let skylarkPath: String
    let angles: GeometryAngles
    let structuredData: String

    var title: String { PageTag.title }
    var lang: String { "en" }

    var head: some HTML {
        meta(.name(.viewport), .content("width=device-width, initial-scale=1, viewport-fit=cover"))
        for tag in PageTag.all { tag }
        link(.init(name: "rel", value: "canonical"), .href(PageTag.origin + "/"))
        link(.href("favicon.png"), .rel(.icon), .init(name: "type", value: "image/png"), .init(name: "sizes", value: "96x96"))
        link(.href("skylark.svg"), .rel(.icon), .init(name: "type", value: "image/svg+xml"))
        link(.href("apple-touch-icon.png"), .init(name: "rel", value: "apple-touch-icon"), .init(name: "sizes", value: "180x180"))
        HTMLRaw("<script type=\"application/ld+json\">\(structuredData)</script>")
        HTMLRaw("<style>\n\(styles)\n\(angles.css)\n\(Self.timelines)\n\(Arrow.css)\n</style>")
    }

    /// Each chapter's section and the closing page name a view timeline; the field's layers follow them.
    static var timelines: String {
        let names = (["--intro"] + Layer.all.map(\.timeline)).joined(separator: ", ")
        return "body { timeline-scope: \(names); }\n"
            + Layer.all.map { ".s-\($0.name) { animation-timeline: \($0.timeline); }\n.s-\($0.name) .joins { animation-timeline: \($0.timeline); }" }.joined(separator: "\n")
            + "\n.dust { animation-timeline: \(Chapter.allCases.first?.timeline ?? Layer.constellation.timeline); }"
    }

    var body: some HTML {
        div(.class("night"), .init(name: "aria-hidden", value: "true")) {}
        HTMLRaw(field.html)

        // the web app's header and wordmark, from the shared brand stylesheet
        header(.class("page-header bar")) {
            nav(.class("app-nav-links"), .init(name: "aria-label", value: "Main")) {
                a(.class("nav-link hide-narrow"), .href("#\(Departure.headline.next.id)")) { "The idea" }
                // the code isn't public yet: GitHub shows, greyed out, and goes nowhere
                span(.class("nav-link off"), .init(name: "aria-disabled", value: "true"), .title("Coming soon")) { "GitHub" }
            }
        }
        a(.href("#\(Stop.sky.id)"), .class("wordmark mark"), .init(name: "aria-label", value: "Turgai home")) {
            HTMLRaw("<svg class=\"mark-bird\" viewBox=\"0 0 1024 1024\" aria-hidden=\"true\"><path fill-rule=\"evenodd\" d=\"\(skylarkPath)\"/></svg>")
            span(.class("wordmark-text")) { "turgai" }
        }
        // the big word in the sky only moves and shrinks into the logo, so it stays on the compositor
        span(.class("hero-word"), .init(name: "aria-hidden", value: "true")) { span(.class("hero-in")) { "turgai" } }
        for arrow in Arrow.all { arrow }

        main(.class("page")) {
            section(.class("intro"), .id(Stop.sky.id)) {
                // two small snap points, not the whole intro: a snap area taller than the screen scrolls freely inside
                span(.class("snap"), .init(name: "aria-hidden", value: "true")) {}
                span(.class("snap end"), .id(Stop.headline.id), .init(name: "aria-hidden", value: "true")) {}
                div(.class("stage")) {
                    // one video per theme; CSS shows the one that matches, so switching theme needs no reload
                    for sky in Sky.allCases { SkyVideo(sky: sky) }
                    div(.class("veil")) {}
                    div(.class("sky-copy")) {
                        p(.class("eyebrow")) { "Turgai, an agent harness built on objects"; ComingSoon() }
                        h1 { "Turgai extends "; span(.class("flag")) { "your product." } }
                        p(.class("answer")) { "Plug AI agents into your product today. Add tools, rules and whole features tomorrow, by asking or in code, while everything keeps running." }
                    }
                }
            }

            for chapter in Chapter.allCases { ChapterSection(chapter: chapter) }

            section(.class("finale"), .id(Stop.closing.id), .init(name: "style", value: "view-timeline-name: \(Layer.constellation.timeline)")) {
                div(.class("finale-main")) {
                    ComingSoon()
                    p(.class("big")) { "Small bird. "; span(.class("flag")) { "Big possibilities." } }
                    div(.class("close")) {
                        p { "Have something your product should do? Turgai is open source and in early alpha. Tell us what you’re building." }
                        div(.class("cta")) {
                            span(.class("button button-accent off"), .init(name: "aria-disabled", value: "true"), .title("Coming soon")) { "See it on GitHub" }
                            a(.class("button button-secondary"), .href("mailto:hello@turg.ai")) { "Write to us" }
                        }
                    }
                }
                footer {
                    span { "Turgai · Apache 2.0 · early development" }
                    span { "Turgai means skylark. Video: Pexels." }
                }
            }
        }
    }
}

/// The tag saying Turgai isn't out yet, on the headline and on the last page.
struct ComingSoon: HTML {
    var body: some HTML {
        span(.class("soon")) { "Coming soon" }
    }
}

/// What search engines and link previews read about the page.
struct PageTag: HTML {
    /// Whether the tag is a standard `name` tag or an Open Graph `property` tag.
    enum Kind { case name, property }

    let kind: Kind
    let key: String
    let value: String
    var media: String? = nil

    /// Where the site lives; link previews need full addresses.
    static let origin = "https://turg.ai"
    static let title = "Turgai — an agent harness built on objects"
    static let description = "Turgai is an agent harness for adding AI agents to your product. Add tools, rules and features while everything keeps running. Any model, wherever you run it."

    static let all: [PageTag] = [
        PageTag(kind: .name, key: "description", value: description),
        PageTag(kind: .name, key: "application-name", value: "Turgai"),
        PageTag(kind: .name, key: "theme-color", value: "#ffffff", media: "(prefers-color-scheme: light)"),
        PageTag(kind: .name, key: "theme-color", value: "#09151e", media: "(prefers-color-scheme: dark)"),
        PageTag(kind: .property, key: "og:type", value: "website"),
        PageTag(kind: .property, key: "og:site_name", value: "Turgai"),
        PageTag(kind: .property, key: "og:title", value: title),
        PageTag(kind: .property, key: "og:description", value: description),
        PageTag(kind: .property, key: "og:url", value: origin + "/"),
        PageTag(kind: .property, key: "og:image", value: "\(origin)/\(Preview.file)"),
        PageTag(kind: .property, key: "og:image:width", value: "\(Int(Preview.size.width))"),
        PageTag(kind: .property, key: "og:image:height", value: "\(Int(Preview.size.height))"),
        PageTag(kind: .property, key: "og:image:alt", value: "The word turgai over a blue sky with clouds"),
        PageTag(kind: .name, key: "twitter:image", value: "\(origin)/\(Preview.file)"),
        PageTag(kind: .name, key: "twitter:card", value: "summary_large_image"),
        PageTag(kind: .name, key: "twitter:title", value: title),
        PageTag(kind: .name, key: "twitter:description", value: description),
    ]

    var body: some HTML {
        switch kind {
        case .name:
            if let media {
                meta(.init(name: "name", value: key), .content(value), .init(name: "media", value: media))
            } else {
                meta(.init(name: "name", value: key), .content(value))
            }
        case .property:
            meta(.init(name: "property", value: key), .content(value))
        }
    }
}

/// One chapter's screen: the claim on the left (about any product), the proof on the right (Dopline doing it),
/// under the field. A chapter without an example shows the field alone beside its claim.
struct ChapterSection: HTML {
    let chapter: Chapter

    var body: some HTML {
        section(.class("beat beat-\(chapter.rawValue)"), .id(Stop.chapter(chapter).id), .init(name: "style", value: "view-timeline-name: \(chapter.timeline)")) {
            div(.class("copy")) {
                h2 { chapter.title }
                chapter.claim
            }
            if let proof = chapter.proof {
                div(.class("proof")) {
                    p(.class("proof-label")) { proof.label }
                    p(.class("proof-text")) { proof.text }
                    proof.exhibit
                }
            }
        }
    }
}

extension Chapter {
    var title: String {
        switch self {
        case .inside: "Plug agents into what you already run."
        case .grows: "Every new idea becomes a new part."
        case .trust: "Your product holds, whatever fails."
        case .yours: "Your model, your choice."
        case .why: "Every part is an object."
        }
    }

    /// The claim, true for any product.
    @HTMLBuilder var claim: some HTML {
        switch self {
        case .inside:
            p { "You or your developer connect it once. Turgai runs next to your service: your app talks to it through its API, your customers write to it in Telegram, and it reaches your systems, whatever they’re built in." }
        case .grows:
            p { "From then on, you grow it by asking: say what you need, and an agent writes the new part. Or write it in code yourself. "; strong { "The new part joins what’s already there. Nothing is rebuilt, nothing stops." } }
        case .trust:
            p { "A supplier that stops answering, a model that’s down or wrong: no part loses what it knew, and none breaks your rules. "; strong { "Your rules are kept by Turgai, not left to the model." } }
        case .yours:
            p { "Run as many agents as you need, and set each one up: its model, how it speaks, what it’s told to do. Apple’s on‑device model, Ollama, or any OpenAI‑compatible API. Run it on your own Mac, your own server or in the cloud, on one machine or spread across many. A local model costs nothing to run." }
            p { strong { "Swap a model, and the product stays." } }
        case .why:
            p { "Each part, from a supplier to a rule to every agent, runs on its own, keeps its own data, and talks to the others by messages, like programs on an operating system, on one machine or across many." }
            p { strong { "That’s why your product can keep growing without starting over." } }
        }
    }

    /// What happened in Dopline, the imagined travel agency that proves the claim, and what it looks like there.
    var proof: Proof? {
        switch self {
        case .inside:
            Proof(
                label: "For example",
                text: "Imagine Dopline, a small travel agency run by Anna. Her developer plugs two agents into its app, and now travellers just write.",
                exhibit: .chat(Chat(
                    title: "Dopline · Telegram", ask: "10 days in Japan in April. Two kids, my mother can’t walk much, we love food.",
                    reply: "Here’s a first plan: step-free hotels, short walks, a food tour in Osaka. It comes to €9,200, so Anna will confirm it today."
                ))
            )
        case .grows:
            Proof(
                label: "At Dopline",
                text: "Anna, who runs Dopline, said “Trips over €8,000 need my approval.” Dopline’s planner agent wrote this trip desk, and Turgai checked it before it ran. Later she asked for group tours the same way.",
                exhibit: .code(Code(label: "The trip desk, written by the planner", source: Code.yamlSample))
            )
        case .trust:
            Proof(
                label: "At Dopline",
                text: "When a flight is cancelled, Dopline rebooks everyone on it, and no trip over €8,000 goes through without Anna.",
                exhibit: .trip(Trip())
            )
        case .yours:
            Proof(
                label: "At Dopline",
                text: "Two agents, each set up for its job: a small local model talks to travellers, a bigger one plans the trips.",
                exhibit: .agents([
                    AgentCard(name: "concierge", model: "Local · Ollama",
                              instructions: "Answer travellers. Pass trip plans to the planner."),
                    AgentCard(name: "planner", model: "Cloud · OpenAI",
                              instructions: "Plan trips. Send anything over €8,000 to Anna."),
                ])
            )
        case .why:
            nil
        }
    }
}

/// Dopline doing what a chapter claims: a label, a sentence, and the thing it shows.
/// The first proof introduces Dopline, so its label says it's an example; the later ones just name it.
struct Proof {
    let label: String
    let text: String
    let exhibit: Exhibit
}

/// What a proof looks like in Dopline's product.
enum Exhibit: HTML {
    case chat(Chat)
    case code(Code)
    case trip(Trip)
    case agents([AgentCard])

    var body: some HTML {
        switch self {
        case .chat(let chat): chat
        case .code(let code): code
        case .trip(let trip): trip
        case .agents(let agents): div(.class("agent-cards")) { for agent in agents { agent } }
        }
    }
}

/// One agent's settings, cut down to what tells two agents apart: its model and what it's told to do.
struct AgentCard: HTML {
    let name: String
    let model: String
    let instructions: String

    var body: some HTML {
        div(.class("panel agent-card")) {
            p(.class("panel-title")) { name }
            p(.class("agent-model")) { model }
            p(.class("agent-instructions")) { instructions }
        }
    }
}

/// Dopline's trip page as a flight is cancelled and everyone is rebooked, replayed in a loop.
struct Trip: HTML {
    var body: some HTML {
        div(.class("panel shop")) {
            p(.class("panel-title")) { "dopline.travel · trips"; span(.class("live")) { "live" } }
            div(.class("order")) {
                div(.class("order-art"), .init(name: "aria-hidden", value: "true")) {}
                div {
                    p(.class("order-name")) { "Kyoto group · 12 travellers" }
                    p(.class("order-meta")) { "Flight JL 46 · Tokyo → Osaka" }
                }
            }
            p(.class("status")) {
                span(.class("status-before")) { "Flight cancelled" }
                span(.class("status-after")) { "Rebooked · 12 travellers told" }
            }
            p(.class("order-note")) { "New flight JL 48, same day, two hours later" }
        }
    }
}

/// A short chat: a message, the typing dots, and the reply, replayed in a loop.
struct Chat: HTML {
    let title: String
    let ask: String
    let reply: String

    var body: some HTML {
        div(.class("panel chat")) {
            p(.class("panel-title")) { title }
            p(.class("bubble from-customer")) { ask }
            p(.class("bubble typing"), .init(name: "aria-hidden", value: "true")) { span {}; span {}; span {} }
            p(.class("bubble from-bot")) { reply }
        }
    }
}

/// The intro's sky, one per theme.
enum Sky: String, CaseIterable {
    case day, night

    var label: String {
        switch self {
        case .day: "Clouds drifting across a blue sky"
        case .night: "Clouds drifting across a starry night sky"
        }
    }

    /// The file name, without extension, of this sky in a format.
    func file(_ format: VideoFormat) -> String {
        let base = switch self {
        case .day: "sky"
        case .night: "sky-night"
        }
        return format.suffix.isEmpty ? base : "\(base)-\(format.suffix)"
    }
}

/// The formats each sky is encoded in, smallest first; a browser plays the first it can decode.
enum VideoFormat: CaseIterable {
    /// The smallest; Safari plays it only on chips with an AV1 decoder (A17 Pro, M3 and later).
    case av1
    /// About half of H.264; Safari plays it on practically every Apple device.
    case hevc
    /// The fallback every browser plays.
    case h264

    var suffix: String {
        switch self {
        case .av1: "av1"
        case .hevc: "hevc"
        case .h264: ""
        }
    }

    var type: String {
        switch self {
        case .av1: "video/mp4; codecs=\"av01.0.05M.08\""
        case .hevc: "video/mp4; codecs=\"hvc1\""
        case .h264: "video/mp4"
        }
    }
}

struct SkyVideo: HTML {
    let sky: Sky

    var body: some HTML {
        video(
            .class("sky sky-\(sky.rawValue)"), .init(name: "autoplay", value: nil), .init(name: "muted", value: nil),
            .init(name: "loop", value: nil), .init(name: "playsinline", value: nil),
            .init(name: "preload", value: "auto"), .init(name: "aria-label", value: sky.label)
        ) {
            for format in VideoFormat.allCases {
                source(.src("\(sky.file(format)).mp4"), .init(name: "type", value: format.type))
            }
        }
    }
}

/// The arrow at the bottom of the screen that jumps to the next stop.
/// There is one per stop that has a next one, stacked in the same place; scroll shows only the current one.
struct Arrow: HTML {
    let from: Departure

    private init(from: Departure) {
        self.from = from
    }

    static var all: [Arrow] { Departure.all.map(Arrow.init) }

    /// The timeline the arrow follows, and when it shows, as a share of that timeline's range in percent.
    private var timing: (timeline: String, range: String, shown: ClosedRange<Double>) {
        switch from {
        case .sky: ("--intro", "contain 0% exit 40%", 0...18)
        case .headline: ("--intro", "contain 0% exit 40%", 64...88)
        case .chapter(let chapter): (chapter.timeline, "cover", 42...58)
        }
    }

    private var name: String { "go-\(from.stop.id)" }

    static var css: String {
        all.map { arrow in
            let timing = arrow.timing
            let fadeIn = max(timing.shown.lowerBound - 5, 0)
            let fadeOut = min(timing.shown.upperBound + 5, 100)
            let hidden = "opacity: 0; visibility: hidden;"
            let visible = "opacity: 1; visibility: visible;"
            let before = timing.shown.lowerBound == 0 ? "" : "0%, \(fadeIn)% { \(hidden) } "
            return ".\(arrow.name) { animation-name: \(arrow.name); animation-timeline: \(timing.timeline); animation-range: \(timing.range); }\n"
                + "@keyframes \(arrow.name) { \(before)\(timing.shown.lowerBound)%, \(timing.shown.upperBound)% { \(visible) } \(fadeOut)%, 100% { \(hidden) } }"
        }.joined(separator: "\n")
    }

    var body: some HTML {
        a(.class("go \(name)"), .href("#\(from.next.id)"), .init(name: "aria-label", value: "Next")) {
            HTMLRaw("<svg viewBox=\"0 0 24 24\" aria-hidden=\"true\"><path d=\"M5 9l7 7 7-7\"/></svg>")
        }
    }
}

/// A short code sample. The source is trusted markup: `<b>` marks keywords, `&lt;` escapes.
struct Code: HTML {
    let label: String
    let source: String

    var body: some HTML {
        pre(.class("code"), .init(name: "aria-label", value: label)) {
            code { HTMLRaw(source) }
        }
    }

    static let swiftSample = """
        <b>@Discoverable</b>
        distributed actor Flights {
          /// Rebook a traveller on the next flight
          /// to the same city, the same day if possible.
          distributed func rebook(traveller: Traveller, from flight: FlightNumber)
        }
        """

    static let yamlSample = """
        <b>behavior:</b> trip desk
        <b>fields:</b>
          approveBelow: 8000
        <b>receive:</b>
          - on: tripPlanned(trip, total)
            when: total &lt; approveBelow
            do:
              - send: bookings.confirm(trip)
          - on: tripPlanned(trip, total)
            do:
              - send: owner.approve(trip)
        """
}

/// The brand's tilted geometry, picked once per build.
struct GeometryAngles {
    let primary: Double
    let secondary: Double
    let tertiary: Double

    static var random: GeometryAngles {
        GeometryAngles(primary: .random(in: -7...7), secondary: .random(in: -6...6), tertiary: .random(in: -5...5))
    }

    var css: String {
        String(format: ":root { --ga1: %.1fdeg; --ga2: %.1fdeg; --ga3: %.1fdeg; }", primary, secondary, tertiary)
    }
}

@main
struct TurgaiSite {
    static func main() async throws {
        let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appending(path: "Clients/Website", directoryHint: .isDirectory)
        let files = FileManager.default
        if files.fileExists(atPath: output.path) { try files.removeItem(at: output) }
        try files.createDirectory(at: output, withIntermediateDirectories: true)

        let skylark = try Skylark(svg: String(contentsOf: TurgaiBrandAssets.skylark, encoding: .utf8))
        let page = LandingPage(
            // the shared brand stylesheet first, then what only the landing page needs
            styles: try String(contentsOf: TurgaiBrandAssets.stylesheet, encoding: .utf8) + "\n"
                + String(contentsOf: resource("website", "css"), encoding: .utf8),
            field: Field(birdPoints: skylark.points(atLeast: 130)),
            skylarkPath: skylark.pathData,
            angles: .random,
            structuredData: try Discovery.structuredData()
        )
        try page.render().write(to: output.appending(path: "index.html"), atomically: true, encoding: .utf8)

        for sky in Sky.allCases {
            for format in VideoFormat.allCases {
                let name = sky.file(format)
                try files.copyItem(at: resource(name, "mp4"), to: output.appending(path: "\(name).mp4"))
            }
        }
        try files.copyItem(at: TurgaiBrandAssets.skylark, to: output.appending(path: "skylark.svg"))
        try skylark.writeIcon(size: 96, to: output.appending(path: "favicon.png"))
        try skylark.writeIcon(size: 180, to: output.appending(path: "apple-touch-icon.png"))
        try Discovery.writeFiles(to: output)
        try await Preview.render(sky: resource(Sky.day.file(.h264), "mp4"), to: output.appending(path: Preview.file))
        try """
        /*
          X-Content-Type-Options: nosniff
          Referrer-Policy: strict-origin-when-cross-origin
          Content-Security-Policy: default-src 'none'; script-src 'none'; style-src 'self' 'unsafe-inline'; img-src 'self'; media-src 'self'; font-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'
          X-Frame-Options: DENY

        """
            .write(to: output.appending(path: "_headers"), atomically: true, encoding: .utf8)
        print("Generated \(output.path)")
    }

    private static func resource(_ name: String, _ ext: String) throws -> URL {
        guard let url = Bundle.module.url(forResource: name, withExtension: ext) else { throw CocoaError(.fileNoSuchFile) }
        return url
    }
}
