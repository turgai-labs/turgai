import Foundation

/// A position in the field's 1000 × 1000 drawing.
struct Point {
    var x: Double
    var y: Double
}

/// Whether a node's small note is drawn under its name.
enum Notes {
    case shown, hidden
}

/// The palette role of a mark; CSS maps each to a brand token.
enum Tone: String {
    case ink, life, message
}

/// Where a node's name and note sit: on the side its links leave free.
enum Side {
    case above, below, leading, trailing
}

/// One object drawn in the field.
struct Node {
    let name: String
    /// A word or two under the name, if the node has one.
    let note: String?
    let at: Point
    let radius: Double
    let tone: Tone
    let label: Side

    init(_ name: String, note: String? = nil, at x: Double, _ y: Double, radius: Double = 14, tone: Tone = .ink, label: Side = .trailing) {
        self.name = name
        self.note = note
        self.at = Point(x: x, y: y)
        self.radius = radius
        self.tone = tone
        self.label = label
    }
}

/// A message travelling along a link, drawn as its own HTML dot so the GPU moves it: the dot follows the
/// link's curve through CSS keyframes written in percentages of the picture, so it scales with it.
struct Pulse {
    let from: Point
    let to: Point
    /// Whether the link appears in this scene, so the pulse fades in with it.
    let joining: Bool

    /// The same curve the link is drawn with.
    var control: Point {
        let dx = to.x - from.x, dy = to.y - from.y
        return Point(x: (from.x + to.x) / 2 - dy * 0.18, y: (from.y + to.y) / 2 + dx * 0.18)
    }

    /// One keyframes name per distinct link, shared by every scene that draws it.
    var name: String { "p\(Int(from.x))-\(Int(from.y))-\(Int(to.x))-\(Int(to.y))" }

    /// A dozen points along the curve as keyframes; at this size the steps between them don't show.
    var keyframes: String {
        let steps = 12
        let stops = (0...steps).map { step -> String in
            let t = Double(step) / Double(steps), u = 1 - t, c = control
            let x = u * u * from.x + 2 * u * t * c.x + t * t * to.x
            let y = u * u * from.y + 2 * u * t * c.y + t * t * to.y
            return String(format: "%.1f%% { translate: %.2f%% %.2f%%; }", t * 100, (x + 60) / 11.2, (y + 60) / 11.2)
        }
        return "@keyframes \(name) { \(stops.joined(separator: " ")) }\n.\(name) { animation-name: \(name); }"
    }

    var html: String {
        let lead = (from.x + to.y).truncatingRemainder(dividingBy: 1.7)
        return "<div class=\"pulse-way motion\(joining ? " joins-fade" : "")\"><div class=\"pulse \(name)\" style=\"animation-delay:-\(lead.rounded1)s\"></div></div>"
    }
}

/// What a scene draws: its picture, and the pulses that move over it.
private struct Drawing {
    var art: String
    var pulses: [Pulse] = []

    static func + (lhs: Drawing, rhs: Drawing) -> Drawing {
        Drawing(art: lhs.art + rhs.art, pulses: lhs.pulses + rhs.pulses)
    }
}

/// The animated picture behind the story, drawn at build time.
/// Each scene is its own layer, so fading it with scroll is a compositor-only opacity change that keeps up
/// with fast scrolling. What loops for good is on the GPU too: the pulses are HTML dots moved by CSS, and the
/// dust is a few star layers, each faded, slid or turned whole. The page needs no script.
struct Field {
    let birdPoints: [Point]

    private static let box = "viewBox=\"-60 -60 1120 1120\""

    var html: String {
        let layers = Layer.all.map { layer in
            let drawing = content(layer)
            return "<div class=\"layer scene s-\(layer.name)\"><svg class=\"art\" \(Self.box)>\(drawing.art)</svg>"
                + drawing.pulses.map(\.html).joined() + "</div>"
        }.joined()
        return "<div class=\"field\" aria-hidden=\"true\"><div class=\"layer dust\">\(dust)</div>\(layers)</div>"
    }

    /// The keyframes for every distinct pulse in the picture.
    var css: String {
        var seen = Set<String>()
        return Layer.all.flatMap { content($0).pulses }
            .filter { seen.insert($0.name).inserted }
            .map(\.keyframes).joined(separator: "\n")
    }

    // MARK: - Dopline, growing

    /// A part of Dopline's product, and the chapter in which it joins. The product starts small and grows:
    /// travellers, two agents and the app; then the trip desk, Anna and group tours; then flights and rebooking.
    private enum Part: CaseIterable {
        case traveller, concierge, planner, app, tripDesk, owner, groupTours, flights, rebooking

        var joins: Chapter {
            switch self {
            case .traveller, .concierge, .planner, .app: .inside
            case .tripDesk, .owner, .groupTours: .grows
            case .flights, .rebooking: .trust
            }
        }

        /// The first parts sit in the middle; each later chapter adds parts further out, so the product grows
        /// from the centre. Names sit on the side facing away from the middle, where fewest links run.
        var node: Node {
            switch self {
            case .app: Node("your app", at: 500, 550, radius: 22, label: .above)
            // two agents, each a part like any other, each on its own model
            case .concierge: Node("concierge", note: "agent · small model", at: 320, 440, radius: 20, tone: .message, label: .leading)
            case .planner: Node("planner", note: "agent · big model", at: 680, 410, radius: 20, tone: .message, label: .trailing)
            case .traveller: Node("traveller", note: "Telegram", at: 200, 270, label: .above)
            case .tripDesk: Node("trip desk", note: "approval rule", at: 730, 710, radius: 20, tone: .life, label: .trailing)
            case .owner: Node("Anna", note: "owner", at: 880, 550, label: .above)
            case .groupTours: Node("group tours", note: "by the planner", at: 560, 890, tone: .life, label: .below)
            case .flights: Node("flights", note: "supplier API", at: 190, 690, label: .leading)
            case .rebooking: Node("rebooking", note: "by the planner", at: 260, 900, tone: .life, label: .below)
            }
        }
    }

    /// Who talks to whom. A few links cross, like messages do. A link bends to the left of its direction,
    /// so the order of a pair decides which way it curves (planner → concierge arcs over the app's name).
    private static let links: [(Part, Part)] = [
        (.traveller, .concierge), (.planner, .concierge), (.concierge, .app), (.planner, .app),
        (.planner, .tripDesk), (.tripDesk, .app), (.tripDesk, .owner), (.groupTours, .tripDesk), (.groupTours, .app),
        (.flights, .app), (.rebooking, .flights), (.rebooking, .concierge),
    ]

    /// A link appears once both its ends have joined.
    private static func chapter(of link: (Part, Part)) -> Chapter { max(link.0.joins, link.1.joins) }

    /// The parts that stop and come back while the product is recovering.
    private static let restartingParts: [Part] = [.flights, .planner, .app, .tripDesk]

    private func content(_ layer: Layer) -> Drawing {
        switch layer {
        case .chapter(let chapter):
            switch chapter.scene {
            case .product: product(after: chapter, restarting: [])
            case .recovering: product(after: chapter, restarting: Self.restartingParts)
            case .agents: agents
            case .distributed: Drawing(art: machines) + product(after: chapter, restarting: [])
            }
        case .constellation: Drawing(art: constellation)
        }
    }

    /// Two machines behind the product, each holding some of its parts; the links between them are messages
    /// going from one machine to the other. They ease in with the chapter.
    private var machines: String {
        // each box holds its parts and their names; the gap between them is where messages cross
        let boxes = [
            (name: "machine 1", from: Point(x: -25, y: 160), to: Point(x: 390, y: 1000)),
            (name: "machine 2", from: Point(x: 420, y: 350), to: Point(x: 1000, y: 1000)),
        ]
        let drawn = boxes.map { box in
            "<rect class=\"machine\" x=\"\(box.from.x)\" y=\"\(box.from.y)\" width=\"\(box.to.x - box.from.x)\" height=\"\(box.to.y - box.from.y)\" rx=\"36\"/>"
                + text(box.name, at: Point(x: box.from.x + 24, y: box.from.y - 16), anchor: "start", style: "machine-label")
        }.joined()
        return "<g class=\"joins\">\(drawn)</g>"
    }

    /// Several agents, each changing its model on its own, and the kinds of parts around them.
    private var agents: Drawing {
        let models = ["model: Apple on-device", "model: Ollama", "model: OpenAI-compatible"]
        let concierge = Node("concierge", note: "agent", at: 500, 330, radius: 24, tone: .message)
        let planner = Node("planner", note: "agent", at: 500, 640, radius: 24, tone: .message)
        let memory = Node("memory", note: "what happened", at: 170, 210, tone: .life)
        let systems = Node("your systems", note: "what it can do", at: 830, 210, label: .leading)
        let rules = Node("your rules", note: "what it may do", at: 170, 780, tone: .life)
        let people = Node("people", note: "who it talks to", at: 830, 780, label: .leading)
        let links = [(concierge, people), (concierge, memory), (concierge, planner), (planner, systems), (planner, rules), (planner, memory)]
        // the two agents start on different models and switch out of step
        func swapping(_ agent: Node, startingAt first: Int, after delay: Double) -> String {
            let order = Array(models[first...] + models[..<first])
            return cycle(order, for: agent, every: 2.4, after: delay) + switching(agent, every: 2.4, after: delay)
        }
        // everything inside one boundary: it all runs on Dopline's own server, and only models plug in from outside
        let server = "<rect class=\"machine\" x=\"90\" y=\"140\" width=\"820\" height=\"720\" rx=\"36\"/>"
            + text("dopline’s server", at: Point(x: 114, y: 124), anchor: "start", style: "machine-label")
        let art = server + links.map { link($0.0, $0.1) }.joined() + [memory, systems, rules, people].map(node).joined()
            + [concierge, planner].map { node($0, .hidden) + still(note("any model", for: $0)) }.joined()
            + motion(swapping(concierge, startingAt: 1, after: 0) + swapping(planner, startingAt: 2, after: 1.2))
        return Drawing(art: art, pulses: links.map { Pulse(from: $0.0.at, to: $0.1.at, joining: false) })
    }

    /// A ring around a node each time its model is swapped, in step with `cycle`.
    private func switching(_ node: Node, every seconds: Double, after delay: Double) -> String {
        let r = node.radius
        let timing = "dur=\"\(seconds)s\" begin=\"\(delay)s\" repeatCount=\"indefinite\""
        return "<circle class=\"ring\" cx=\"\(node.at.x)\" cy=\"\(node.at.y)\" r=\"\(r + 4)\" opacity=\"0\">"
            + "<animate attributeName=\"r\" values=\"\(r + 4);\(r + 40);\(r + 40)\" keyTimes=\"0;0.4;1\" \(timing)/>"
            + "<animate attributeName=\"opacity\" values=\"0.8;0;0\" keyTimes=\"0;0.4;1\" \(timing)/></circle>"
    }

    /// Several notes taking turns under one node.
    private func cycle(_ values: [String], for node: Node, every seconds: Double, after delay: Double) -> String {
        let place = notePosition(for: node)
        let period = seconds * Double(values.count)
        let share = 1 / Double(values.count)
        return values.enumerated().map { index, value in
            discrete(
                text(value, at: place.0, anchor: place.1, style: "note"),
                values: "1;0;0", keyTimes: "0;\(share);1",
                timing: "dur=\"\(period)s\" begin=\"\(delay + Double(index) * seconds)s\" repeatCount=\"indefinite\""
            )
        }.joined()
    }

    /// The product as it stands after a chapter: everything from before, plus what joins in this chapter, which
    /// eases in as the section scrolls into view. Restarting parts stop one at a time and come back.
    private func product(after chapter: Chapter, restarting restartingParts: [Part]) -> Drawing {
        func eased(_ drawn: String, joining step: Chapter) -> String {
            step == chapter ? "<g class=\"joins\">\(drawn)</g>" : drawn
        }
        let present = Self.links.filter { Self.chapter(of: $0) <= chapter }
        let links = present.map { link in eased(self.link(link.0.node, link.1.node), joining: Self.chapter(of: link)) }
        let pulses = present.map { Pulse(from: $0.0.node.at, to: $0.1.node.at, joining: Self.chapter(of: $0) == chapter) }
        // parts that restart drop their usual note here, so "stopped" and "back" have the spot to themselves
        let parts = Part.allCases.filter { $0.joins <= chapter }.map { part in
            let drawn = restartingParts.contains(part)
                ? node(part.node, .hidden) + still(notes(of: part.node))
                : node(part.node)
            return eased(drawn, joining: part.joins)
        }
        let restarts = motion(restarting(restartingParts.map(\.node)))
        return Drawing(art: links.joined() + parts.joined() + restarts, pulses: pulses)
    }

    /// One part at a time stops and comes back; the rest keep working.
    private func restarting(_ members: [Node]) -> String {
        let period = 8.0
        return members.enumerated().map { index, member in
            stopping(member, period: period, begin: Double(index) * period / Double(members.count))
        }.joined()
    }

    private var constellation: String {
        var seed: UInt64 = 7
        func random() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(seed >> 11) / Double(1 << 53)
        }
        let points = birdPoints.map { Point(x: $0.x * 1000, y: $0.y * 1000) }
        let nearest = points.indices.flatMap { a in points.indices.filter { $0 > a }.map { b in (a, b, distance(points[a], points[b])) } }
        let shortest = nearest.map(\.2).min() ?? 0
        let lines = nearest.filter { $0.2 < shortest * 1.25 }
            .map { "M\(points[$0.0].x.rounded1) \(points[$0.0].y.rounded1)L\(points[$0.1].x.rounded1) \(points[$0.1].y.rounded1)" }
            .joined()
        let stars = points.map { point in
            let from = Point(x: random() * 1120 - 60, y: random() * 1120 - 60)
            return "<circle class=\"star\" cx=\"\(point.x.rounded1)\" cy=\"\(point.y.rounded1)\" r=\"6\" "
                + "style=\"--dx:\((from.x - point.x).rounded1)px;--dy:\((from.y - point.y).rounded1)px\"/>"
        }
        return "<path class=\"constellation\" d=\"\(lines)\"/>" + stars.joined()
    }

    /// Faint background stars, the same in every scene: six star layers that the GPU twinkles, drifts or turns
    /// whole, and a resting copy for visitors who prefer reduced motion.
    private var dust: String {
        var seed: UInt64 = 42
        func random() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(seed >> 11) / Double(1 << 53)
        }
        let stars = (0..<46).map { _ in
            "<circle cx=\"\((random() * 1120 - 60).rounded1)\" cy=\"\((random() * 1120 - 60).rounded1)\" r=\"\((1.5 + random() * 2.5).rounded1)\"/>"
        }
        let groups = ["orbit-a", "twinkle-a", "drift-a", "orbit-b", "twinkle-b", "drift-b"]
        let moving = groups.enumerated().map { index, group in
            "<svg class=\"art motion dust-\(group)\" \(Self.box)>"
                + stars.indices.filter { $0 % groups.count == index }.map { stars[$0] }.joined() + "</svg>"
        }.joined()
        return "<svg class=\"art still\" \(Self.box)>\(stars.joined())</svg>" + moving
    }

    // MARK: - Shared pieces

    private func stopping(_ member: Node, period: Double, begin: Double) -> String {
        let at = member.at
        let r = member.radius
        let timing = "dur=\"\(period)s\" begin=\"\(begin)s\" repeatCount=\"indefinite\""
        let down = "values=\"0;1;1;0;0\" keyTimes=\"0;0.025;0.1375;0.175;1\""
        let notePoint = notePosition(for: member)
        return "<circle class=\"hole\" cx=\"\(at.x)\" cy=\"\(at.y)\" r=\"\(r + 2)\" opacity=\"0\"><animate attributeName=\"opacity\" \(down) \(timing)/></circle>"
            + "<circle class=\"outline t-\(member.tone.rawValue)\" cx=\"\(at.x)\" cy=\"\(at.y)\" r=\"\(r)\" opacity=\"0\"><animate attributeName=\"opacity\" \(down) \(timing)/></circle>"
            + "<circle class=\"ring\" cx=\"\(at.x)\" cy=\"\(at.y)\" r=\"\(r + 4)\" opacity=\"0\">"
            + "<animate attributeName=\"r\" values=\"\(r + 4);\(r + 4);\(r + 34);\(r + 34)\" keyTimes=\"0;0.1375;0.26;1\" \(timing)/>"
            + "<animate attributeName=\"opacity\" values=\"0;0;0.8;0;0\" keyTimes=\"0;0.137;0.1375;0.26;1\" \(timing)/></circle>"
            + discrete(text("stopped", at: notePoint.0, anchor: notePoint.1, style: "note"), values: "0;1;0", keyTimes: "0;0.025;0.1375", timing: timing)
            + discrete(text("back · state restored", at: notePoint.0, anchor: notePoint.1, style: "note"), values: "0;1;0", keyTimes: "0;0.1375;0.3", timing: timing)
    }

    private func node(_ node: Node) -> String { self.node(node, .shown) }

    private func node(_ node: Node, _ notes: Notes) -> String {
        let label = labelPosition(for: node)
        return "<circle class=\"t-\(node.tone.rawValue)\" cx=\"\(node.at.x)\" cy=\"\(node.at.y)\" r=\"\(node.radius)\"/>"
            + (node.tone == .life ? "<circle class=\"glow t-life\" cx=\"\(node.at.x)\" cy=\"\(node.at.y)\" r=\"\(node.radius * 2.6)\"/>" : "")
            + text(node.name, at: label.0, anchor: label.1, style: "label")
            + (notes == .shown ? self.notes(of: node) : "")
    }

    /// The node's own note, if it has one.
    private func notes(of node: Node) -> String {
        node.note.map { note($0, for: node) } ?? ""
    }

    private func note(_ value: String, for node: Node) -> String {
        let place = notePosition(for: node)
        return text(value, at: place.0, anchor: place.1, style: "note")
    }

    private func link(_ from: Node, _ to: Node) -> String {
        let dx = to.at.x - from.at.x
        let dy = to.at.y - from.at.y
        let control = Point(x: (from.at.x + to.at.x) / 2 - dy * 0.18, y: (from.at.y + to.at.y) / 2 + dx * 0.18)
        let d = "M\(from.at.x) \(from.at.y)Q\(control.x.rounded1) \(control.y.rounded1) \(to.at.x) \(to.at.y)"
        // its pulse is a separate HTML dot (see Pulse), so the GPU moves it
        return "<path class=\"link\" d=\"\(d)\"/>"
    }

    /// Where the name goes, and how it's anchored.
    private func labelPosition(for node: Node) -> (Point, String) {
        let gap = node.radius + 16
        return switch node.label {
        case .trailing: (Point(x: node.at.x + gap, y: node.at.y - 2), "start")
        case .leading: (Point(x: node.at.x - gap, y: node.at.y - 2), "end")
        case .above: (Point(x: node.at.x, y: node.at.y - gap - 30), "middle")
        case .below: (Point(x: node.at.x, y: node.at.y + gap + 14), "middle")
        }
    }

    /// The note goes under the name.
    private func notePosition(for node: Node) -> (Point, String) {
        let label = labelPosition(for: node)
        return (Point(x: label.0.x, y: label.0.y + 28), label.1)
    }

    private func text(_ value: String, at point: Point, anchor: String, style: String) -> String {
        "<text class=\"\(style)\" x=\"\(point.x.rounded1)\" y=\"\(point.y.rounded1)\" text-anchor=\"\(anchor)\">\(value.escapedForMarkup)</text>"
    }

    private func discrete(_ element: String, values: String, keyTimes: String, timing: String) -> String {
        "<g opacity=\"0\">\(element)<animate attributeName=\"opacity\" calcMode=\"discrete\" values=\"\(values)\" keyTimes=\"\(keyTimes)\" \(timing)/></g>"
    }

    /// Shown only when the visitor prefers reduced motion.
    private func still(_ content: String) -> String { "<g class=\"still\">\(content)</g>" }

    /// Hidden when the visitor prefers reduced motion.
    private func motion(_ content: String) -> String { "<g class=\"motion\">\(content)</g>" }

    private func distance(_ a: Point, _ b: Point) -> Double { ((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)).squareRoot() }
}

extension Double {
    fileprivate var rounded1: String { String(format: "%.1f", self) }
}

extension String {
    var escapedForMarkup: String {
        replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}
