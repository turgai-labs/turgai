/// The selling story, in page order: one reason to choose Turgai per chapter, with Dopline, an imagined
/// small travel agency, as the running proof. Dopline's parts join across the first chapters and stay.
enum Chapter: String, CaseIterable, Comparable {
    /// It lives in your product: the agent joins your app and your customers' channels.
    case inside
    /// It grows piece by piece: every new idea becomes a new part, written in code or by the agent.
    case grows
    /// You can trust it with real work: rules hold, parts restart and pick up where they left off.
    case trust
    /// Independence: no one else holds the keys. Control is its proof: where it runs, your storage, your models, your rules.
    case yours
    /// Why it works: every part is an object.
    case why

    /// The scroll timeline this chapter's section names; its scene and its arrow follow it.
    var timeline: String { "--\(rawValue)" }

    /// The chapter after this one; the last has none.
    var next: Chapter? {
        let all = Self.allCases
        let index = all.firstIndex(of: self)!
        return all.index(after: index) < all.endIndex ? all[all.index(after: index)] : nil
    }

    static func < (lhs: Chapter, rhs: Chapter) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }
}

/// What the field shows beside a chapter.
enum Scene {
    /// Dopline's product as it stands after the chapter; parts that join in it ease in.
    case product
    /// The product, with parts stopping one at a time and coming back.
    case recovering
    /// Several agents, each changing its model, and the kinds of parts around them.
    case agents
    /// The whole product, its parts spread over two machines, messages crossing between them.
    case distributed
}

extension Chapter {
    var scene: Scene {
        switch self {
        case .inside, .grows: .product
        case .trust: .recovering
        case .yours: .agents
        case .why: .distributed
        }
    }
}

/// Every place the page snaps to, in scroll order.
enum Stop: Equatable {
    /// The sky with the big wordmark.
    case sky
    /// The sky with the headline, after the wordmark has become the logo.
    case headline
    case chapter(Chapter)
    /// The last page, at night. It has nowhere further to go.
    case closing

    /// The anchor id the page uses for this stop. Arrows are named after it (`go-<id>`), so no id may read like
    /// a "back to top" button: ad blockers' annoyance lists hide elements called `go-top` and the like.
    var id: String {
        switch self {
        case .sky: "sky"
        case .headline: "start"
        case .chapter(let chapter): chapter.rawValue
        case .closing: "end"
        }
    }
}

/// A stop the visitor can leave by the arrow: every stop but the closing page, so each one has a next.
enum Departure {
    case sky
    case headline
    case chapter(Chapter)

    static var all: [Departure] { [.sky, .headline] + Chapter.allCases.map(Departure.chapter) }

    var stop: Stop {
        switch self {
        case .sky: .sky
        case .headline: .headline
        case .chapter(let chapter): .chapter(chapter)
        }
    }

    var next: Stop {
        switch self {
        case .sky: .headline
        case .headline: Chapter.allCases.first.map(Stop.chapter) ?? .closing
        case .chapter(let chapter): chapter.next.map(Stop.chapter) ?? .closing
        }
    }
}

/// What the field shows: one layer per chapter, and the constellation on the closing page.
enum Layer {
    case chapter(Chapter)
    case constellation

    static let all: [Layer] = Chapter.allCases.map(Layer.chapter) + [.constellation]

    var name: String {
        switch self {
        case .chapter(let chapter): chapter.rawValue
        case .constellation: "closing"
        }
    }

    var timeline: String {
        switch self {
        case .chapter(let chapter): chapter.timeline
        case .constellation: "--closing"
        }
    }
}
