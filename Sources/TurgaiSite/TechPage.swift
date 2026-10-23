import Elementary
import Foundation

/// The tech page, at /tech/: why objects, why distributed actors, why Swift, and how agents, behaviors,
/// effects and plugins combine. A plain article: no scroll story, short real snippets, a few diagrams.
/// Its structure comes from `TechTopic`; nothing here repeats their order.
struct TechPage: HTMLDocument {
    let styles: String
    let skylarkPath: String
    let angles: GeometryAngles

    static let path = "tech/"
    static let title = "How Turgai works — objects, actors, Swift"
    static let description =
        "Everything in Turgai is an object, run by a small core: why objects, why distributed actors, why Swift, and how agents, behaviors and permissions fit into your product."

    var title: String { Self.title }
    var lang: String { "en" }

    var head: some HTML {
        meta(.name(.viewport), .content("width=device-width, initial-scale=1, viewport-fit=cover"))
        meta(.name(.description), .content(Self.description))
        meta(.init(name: "property", value: "og:title"), .content(Self.title))
        meta(.init(name: "property", value: "og:description"), .content(Self.description))
        meta(.init(name: "property", value: "og:url"), .content(PageTag.origin + "/" + Self.path))
        meta(.init(name: "property", value: "og:image"), .content("\(PageTag.origin)/\(Preview.file)"))
        link(.init(name: "rel", value: "canonical"), .href(PageTag.origin + "/" + Self.path))
        link(.href("../" + SitePath.skylark), .rel(.icon))
        link(
            .href("../favicon.png"), .rel(.icon), .init(name: "type", value: "image/png"),
            .init(name: "sizes", value: "96x96"))
        link(
            .href("../apple-touch-icon.png"), .init(name: "rel", value: "apple-touch-icon"),
            .init(name: "sizes", value: "180x180"))
        HTMLRaw("<style>\n\(styles)\n\(angles.css)\n\(Orbit.css)\n</style>")
    }

    var body: some HTML {
        Orbit()
        header(.class("page-header tech-bar")) {
            a(.href("../"), .class("wordmark"), .init(name: "aria-label", value: "Turgai home")) {
                HTMLRaw(
                    "<svg class=\"mark-bird\" viewBox=\"0 0 1024 1024\" aria-hidden=\"true\"><path fill-rule=\"evenodd\" d=\"\(skylarkPath)\"/></svg>"
                )
                span(.class("wordmark-text")) { "turgai" }
            }
            SiteNav(current: .tech)
        }

        main(.class("tech")) {
            div(.class("tech-intro")) {
                p(.class("eyebrow")) { "How it works" }
                h1 {
                    "Everything in Turgai "
                    span(.class("nowrap")) {
                        span(.class("flag")) { "is an object" }
                        ","
                    }
                    " run by a small core."
                }
                p(.class("lede")) {
                    "Agents, the tools they use, the rules a business sets and the parts of a product all run in Turgai as objects, each owning its state and working with the others by exchanging messages. You run the core where you choose, and you decide which models it uses and what every part may do."
                }
            }

            for topic in TechTopic.allCases { TechSection(topic: topic) }
        }
        // the last part, at night like the idea page's last page: a block that covers the orbit as it scrolls in
        section(.class("tech-night")) {
            // built like the idea page's last page: the sticker, the big line, then what it means and the way in
            div(.class("tech-end")) {
                ComingSoon()
                p(.class("big")) {
                    "Start small."
                    br()
                    span(.class("flag")) { "Keep adding." }
                }
                div(.class("close")) {
                    p(.class("belief")) {
                        "An agent, a rule and a part of your product are built and changed in the same way, and new ones join while the rest keeps running."
                    }
                    p { "Turgai is in early alpha. If you’d like to know more or see it running, write to us." }
                    div(.class("cta")) {
                        a(.class("button button-accent"), .href("mailto:hello@turg.ai")) { "Write to us" }
                        a(.class("button button-secondary"), .href("../")) { "Back to the idea" }
                    }
                }
            }
            footer(.class("tech-footer")) {
                span { "Turgai · Apache 2.0 · early development" }
                span { "Turgai means skylark." }
            }
        }
    }
}

/// One part of the tech page's story, in reading order: the ideas first (objects, actors, agents, behaviors,
/// permissions, control, your product), then the language that holds them, then where it stands today.
enum TechTopic: String, CaseIterable {
    case objects, actors, agents, behaviors, effects, control, plugins, swift, status

    /// The small tag beside the part, in the left rail.
    var kicker: String {
        switch self {
        case .objects: "Objects"
        case .actors: "Actors"
        case .swift: "Swift"
        case .agents: "Agents"
        case .behaviors: "Behaviors"
        case .effects: "Effects"
        case .control: "Control"
        case .plugins: "Your product"
        case .status: "Today"
        }
    }

    var title: String {
        switch self {
        case .objects: "Why everything is an object"
        case .actors: "How an object stays alive on its own"
        case .swift: "Why the language matters"
        case .agents: "Agents are objects too"
        case .behaviors: "How agents build objects that last"
        case .effects: "How an agent’s permissions are enforced"
        case .control: "Where Turgai runs and who controls it"
        case .plugins: "Turgai next to your product"
        case .status: "What runs today"
        }
    }

    @HTMLBuilder var text: some HTML {
        switch self {
        case .objects:
            p(.class("lead")) {
                "Turgai builds everything from objects that keep their own state and ask each other to do things, because that is the shape a model can work with: it can find what an object offers, connect objects by messages, and add new ones."
            }
            p {
                "The idea is older than language models, and it has worked before. NeXT built a whole computer on it: developers assembled programs from ready objects and connected them in Interface Builder instead of writing everything, and at CERN in 1990 Tim Berners-Lee wrote the first web browser and web server that way in about two months. Steve Jobs described objects as something like people, which know how to do things and remember what happened."
            }
            figure(.class("photo")) {
                picture {
                    source(
                        .init(name: "srcset", value: "../" + SitePath.nextcubeAVIF),
                        .init(name: "type", value: "image/avif"))
                    img(
                        .src("../" + SitePath.nextcube), .alt("A black NeXTcube computer with its keyboard and mouse"),
                        .init(name: "width", value: "1280"), .init(name: "height", value: "854"),
                        .init(name: "loading", value: "lazy"))
                }
                figcaption {
                    "A NeXTcube, the computer NeXT built around objects. Photo: "
                    a(.href("https://commons.wikimedia.org/wiki/File:Nextcube_1_(26281984242).jpg")) {
                        "Simon Claessen"
                    }
                    ", "
                    a(.href("https://creativecommons.org/licenses/by-sa/2.0/")) { "CC BY-SA 2.0" }
                    ", resized."
                }
            }
            p {
                "Most software since then kept objects inside single programs, joined by integrations written by hand. A model can now do what Interface Builder did for a developer, from a plain request, and because each object keeps its own state and rules, what it puts together stays readable and safe to change. Each object also describes what it offers, so a model can use one it has never seen."
            }
        case .actors:
            p(.class("lead")) {
                "A model can only use an object that is there when it is addressed, and many objects have to keep working while nobody is talking to them, so each needs a life of its own."
            }
            p {
                "An object that keeps its state private and handles one message at a time is an actor, and it needs no locks, as Erlang showed. Turgai’s actors are also distributed, so calling one looks the same on this machine or another, and virtual, so an object is reached by a stable name and wakes when a message arrives. Each accepted change is journaled, and after a crash a new instance rebuilds the same object from that journal. Work left half done still needs its own rule for whether to retry it."
            }
        case .swift:
            p(.class("lead")) {
                "Everything above, objects that keep their own state, messages between them, actors on one machine or many and permissions that cannot leak, usually rests on conventions every contributor has to remember, and conventions wear away as a codebase grows. Turgai is written in Swift because the language enforces most of these rules itself."
            }
            p {
                "Messages are values, so two objects never change the same data. Actors keep each object’s state out of reach, distributed actors make a call across the network as checked as a local one, and ownership lets a permission exist that cannot leave its scope. Because actors can still interleave work while they wait, Hail orders an agent’s turns itself."
            }
            p { "This warehouse is a complete object, and a model can discover it and call it like any other." }
        case .agents:
            p(.class("lead")) {
                "Since everything else is an object, the agent needs no special treatment. In Turgai’s agent layer, Hail, each agent is a distributed virtual actor like any other object, with its own name, journal and history."
            }
            p {
                "It handles a message, calls tools and goes idle, and a turn cut short by a crash or restart is issued again when it next wakes. The model sits behind one interface, so an agent can move from a cloud API to a model on your own machine and keep its name, history and rules. A different model still behaves differently and has to be evaluated before you rely on it."
            }
            p { "Other agents and Turgai’s conversations ask an agent for work in the same way, with one call." }
        case .behaviors:
            p(.class("lead")) {
                "Because agents are objects, what an agent builds for you can be objects too, still working after the conversation that made them is over."
            }
            p {
                "An agent writes them as behaviors, an idea borrowed from Erlang. A behavior is a short YAML document with an object’s fields and what it does with each message, built from a fixed set of conditions and steps with no code. That makes it safe for a model to write and lets the runtime check it before it runs, and redefining a behavior upgrades every object running it."
            }
            p {
                "The trip desk from the main page is one such behavior. It confirms trips under €8,000 and sends the rest to the owner."
            }
        case .effects:
            p(.class("lead")) {
                "An agent that can build and run things needs clear permissions, and they cannot depend on the model following instructions. Hail enforces them at the point where a tool is about to act."
            }
            p {
                "Each tool declares the one effect it has, such as reading files under a path, and before it runs an authority derived from who is asking decides on that effect. It denies anything it does not explicitly grant. A granted effect is a token the compiler keeps from being stored, returned or handed to another actor."
            }
            p {
                "This authority allows files inside one workspace and any network access, and it denies terminal commands simply by not naming them."
            }
        case .control:
            p(.class("lead")) {
                "Permissions settle what an agent may do when a tool acts. A business, especially a public body or a regulated one, also needs to know who runs the system, where its data is kept, who sets its rules and what record it leaves."
            }
            p {
                "Turgai runs where you run it, on a Mac, on your own servers or in a cloud you choose, Linux included, with no Turgai-operated service in between. Conversations, memory and journals stay in your own storage, as files or in PostgreSQL, and what leaves your machines is what you send out, such as calls to a cloud model or messages on Telegram. Each agent’s model, keys and instructions are your configuration, and so are client authentication, channels and permissions. The journal is the system’s record, and every permission decision can be reported to an audit observer you install."
            }
            p {
                "An agent is described by a profile like this one, and the server starts with the authentication you require."
            }
        case .plugins:
            p(.class("lead")) {
                "Running Turgai on your own terms leaves the practical question of how it connects to a product that already has users, data and code of its own."
            }
            p {
                "Turgai owns agents and conversations, while your product keeps its users, decides who may reach each conversation and talks to Turgai over a WebSocket API, so Turgai never needs your user database. Your system itself joins as an object, either a short Swift actor that calls your existing API or a behavior in YAML, and agents then use it like any other object."
            }
        case .status:
            p(.class("lead")) { "Turgai is early, and below is exactly where it stands." }
            div(.class("status")) {
                div {
                    p(.class("status-label")) { "Built" }
                    ul {
                        li { "Distributed virtual actors, journaled to files or PostgreSQL" }
                        li {
                            "Durable workflows with timers, so long-running work can wait for days and survive restarts"
                        }
                        li { "Self-hosted, with no Turgai-operated service in between" }
                        li {
                            "Hail agents with journaled turns, each on its own model: Apple on‑device, Ollama or llama.cpp, or OpenAI, Anthropic, Gemini and any OpenAI‑compatible endpoint"
                        }
                        li { "Behaviors in YAML, checked when defined and upgraded in place" }
                        li { "Scoped effects with deny-by-default authorities, an audit hook and sealed secrets" }
                        li {
                            "A WebSocket conversation API with local, API-key or trusted-proxy auth, a Telegram channel and a Mac app"
                        }
                    }
                }
                div {
                    p(.class("status-label")) { "Next" }
                    ul {
                        li { "A hosted option, for teams that don’t want to run their own servers" }
                        li { "Objects compiled to WebAssembly, written in any language" }
                        li { "Permissions on messages between agents, for many teams on one server" }
                        li { "More channels beyond the API and Telegram, such as WhatsApp and Slack" }
                        li { "A helper agent that prepares context handoffs for long tasks" }
                        li { "The client app beyond the Mac" }
                    }
                }
            }
        }
    }

    /// A small note under the title, for a reader who doesn't know a name the part rests on.
    var note: TopicNote? {
        switch self {
        case .swift:
            TopicNote(
                icon:
                    "<svg viewBox=\"0 0 16 16\" aria-hidden=\"true\"><path fill=\"#f05138\" transform=\"matrix(.351937 0 0 .351937 -1.96558 -2.00601)\" d=\"m46.955 36.578c-.002-.002-.003-.003-.005-.005.066-.223.134-.445.191-.673 2.46-9.799-3.543-21.384-13.701-27.484 4.452 6.035 6.42 13.344 4.671 19.735-.156.571-.343 1.118-.55 1.65-.225-.148-.509-.316-.889-.526 0 0-10.104-6.238-21.055-17.273-.288-.29 5.839 8.757 12.793 16.104-3.276-1.839-12.406-8.482-18.186-13.772.71 1.185 1.555 2.325 2.483 3.423 4.827 6.121 11.121 13.673 18.662 19.473-5.298 3.242-12.785 3.494-20.239.003-1.844-.864-3.577-1.907-5.182-3.091 3.156 5.047 8.015 9.401 13.93 11.943 7.054 3.032 14.068 2.826 19.292.05l-.004.006c.024-.015.054-.031.079-.047.214-.115.427-.232.636-.356 2.51-1.303 7.467-2.625 10.129 2.553.651 1.267 2.036-5.448-3.055-11.713z\"/></svg>",
                text:
                    "Swift is Apple’s open-source, multi-paradigm programming language, with structured concurrency and actors built into the language itself. It is used for apps on Apple devices and for servers on Linux.",
                fine: "Swift and the Swift logo are trademarks of Apple Inc."
            )
        case .objects, .actors, .agents, .behaviors, .effects, .control, .plugins, .status:
            nil
        }
    }

    /// What shows the topic: a real snippet, or a diagram.
    var exhibit: TechExhibit? {
        switch self {
        case .objects: nil
        case .actors: .recovery(Recovery())
        case .swift: .code(Code(label: "The warehouse, a distributed actor in Turgai", source: Self.warehouse))
        case .agents: .code(Code(label: "Asking an agent", source: Self.respond))
        case .behaviors: .code(Code(label: "The trip desk, a behavior", source: Code.yamlSample))
        case .effects: .code(Code(label: "An authority, built as a value", source: Self.authority))
        case .control: .code(Code(label: "One agent’s profile, and the server it runs on", source: Self.profile))
        case .plugins: .stack(Stack.layers)
        case .status: nil
        }
    }

    static let warehouse = """
        <b>@Discoverable</b>
        <b>public distributed actor</b> Warehouse {
          <b>private var</b> received: [WarehouseNote] = []

          <i>/// Tell the warehouse a refund was approved, so it expects the item back.</i>
          <b>public distributed func</b> refundApproved(order: ShopOrder) {
            received.append(WarehouseNote(order: order.number, instruction: .expectReturn))
          }
        }
        """

    /// How one agent asks another, as Hail's agent tool does: find it by its id (wherever it runs, woken if
    /// idle), and call it.
    static let respond = """
        <b>let</b> planner: Agent = <b>try await</b> actorSystem.agent(plannerID)
        <b>let</b> plan: String = <b>try await</b> planner.respond(request)
        """

    static let profile = """
        TurgaiAgentProfile(
          id: "support",
          name: "Support",
          model: <b>try</b> AgentModel(provider: .ollama, id: "qwen3:8b"),
          providerConfiguration: .ollama(baseURL: localOllama, contextWindow: 16_384),
          instructions: "Answer customers. Pass orders to the shop."
        )

        <i># the server, with the authentication you require</i>
        TURGAI_API_KEY=… turgai serve --directory /srv/turgai --api-auth api-key
        """

    static let authority = """
        <b>let</b> authority = CompositeAuthority()
          .granting(for: FileEffect.<b>self</b>, decide: FileEffect.pathPolicy(scopedTo: workspace))
          .grantingAll(for: NetworkEffect.<b>self</b>)
        <i>// TerminalEffect isn't mentioned, so it's denied.</i>
        """
}

/// A small note under a part's title: an icon, one line, and any fine print the icon requires.
struct TopicNote: HTML {
    let icon: String
    let text: String
    let fine: String

    var body: some HTML {
        p(.class("topic-note")) {
            HTMLRaw(icon)
            span {
                text
                " "
                small { fine }
            }
        }
    }
}

/// What illustrates a topic.
enum TechExhibit: HTML {
    case code(Code)
    case diagram(Diagram)
    case stack(Stack)
    case recovery(Recovery)

    var body: some HTML {
        switch self {
        case .code(let code): code
        case .diagram(let diagram): diagram
        case .stack(let stack): stack
        case .recovery(let recovery): recovery
        }
    }
}

/// Layers drawn as square slabs, top to bottom, with what the product plugs in between the first two.
struct Stack: HTML {
    struct Slab {
        let name: String
        let holds: String
        let tone: String
    }

    let slabs: [Slab]
    let plugs: String
    let label: String

    var body: some HTML {
        figure(.class("stack")) {
            for (index, slab) in slabs.enumerated() {
                div(.class("slab slab-\(slab.tone)")) {
                    span(.class("slab-name")) { slab.name }
                    span(.class("slab-holds")) { slab.holds }
                }
                if index == 0 { p(.class("plugs")) { plugs } }
            }
            figcaption { label }
        }
    }

    static let layers = Stack(
        slabs: [
            Slab(name: "Your product", holds: "users, app, data, who sees what", tone: "product"),
            Slab(
                name: "Turgai", holds: "API and channels · conversations · memory · objects and behaviors",
                tone: "turgai"),
            Slab(name: "Hail", holds: "agents · model routing · tools · scoped effects", tone: "hail"),
            Slab(name: "Runtime", holds: "distributed virtual actors · journal and snapshots", tone: "runtime"),
        ],
        plugs: "plugs in models, keys, channels, storage and policy",
        label:
            "Your product keeps its users and rules; Turgai and Hail run agents and objects; the runtime keeps them alive."
    )
}

/// One part of the story: its title, its text, and what shows it.
struct TechSection: HTML {
    let topic: TechTopic

    var body: some HTML {
        // on phones, a snap point at the small clear window before the part, where the orbit shows what it adds
        div(.class("window"), .init(name: "aria-hidden", value: "true")) {}
        section(
            .class("tech-topic"), .id(topic.rawValue),
            .init(name: "style", value: "view-timeline-name: --t-\(topic.rawValue)")
        ) {
            div(.class("rail")) { p(.class("kicker")) { topic.kicker } }
            div(.class("topic-body")) {
                h2 { topic.title }
                if let note = topic.note { note }
                topic.text
                if let exhibit = topic.exhibit { exhibit }
            }
        }
    }
}

/// The trip desk through a crash. It's drawn as every object on the site is, a dot with its name and its current
/// value beside it; its journal is a list on the right. Each change updates its one value, then travels as a pulse to the
/// journal and is appended. The crash breaks the dot and loses the value; the journal stays. The dot restarts in
/// place, its whole journal is selected and dragged back into the dot, and the value steps through each line
/// until it is what it was. CSS opacity and movement only; see `.rc-*`.
struct Recovery: HTML {
    private struct Change {
        let trip: String
        let state: String
        let entry: String
    }

    private let changes = [
        Change(trip: "trip 15", state: "planned", entry: "trip 15 planned"),
        Change(trip: "trip 15", state: "waiting for Anna", entry: "trip 15 sent to Anna"),
        Change(trip: "trip 15", state: "approved", entry: "trip 15 approved"),
    ]
    private let statuses = [
        "running", "crashed · memory lost", "restarted · reading its journal", "replaying 1 of 3", "replaying 2 of 3",
        "replaying 3 of 3", "running · same state as before",
    ]

    var body: some HTML {
        figure(.class("recovery")) {
            div(.class("rc-stage"), .init(name: "aria-hidden", value: "true")) {
                p(.class("rc-head rc-head-journal")) {
                    b { "journal" }
                    " on disk"
                }
                for slot in 0..<3 { span(.class("rc-slot rc-right rc-y\(slot)")) {} }
                for (index, change) in changes.enumerated() {
                    span(.class("rc-row rc-entry rc-right rc-y\(index) rc-j\(index + 1)")) {
                        span(.class("rc-n")) { "\(index + 1)" }
                        change.entry
                    }
                }
                span(.class("rc-select")) {}
                div(.class("rc-ghost")) {
                    for (index, change) in changes.enumerated() {
                        span {
                            span(.class("rc-n")) { "\(index + 1)" }
                            change.entry
                        }
                    }
                }
                span(.class("rc-halo")) {}
                span(.class("rc-obj")) {}
                span(.class("rc-recovering")) { span {} }
                span(.class("rc-broken")) { "✕" }
                span(.class("rc-name")) { "trip desk" }
                for (index, change) in changes.enumerated() {
                    span(.class("rc-state rc-s\(index + 1)")) {
                        span(.class("rc-key")) { change.trip }
                        " "
                        b { change.state }
                    }
                }
                for index in changes.indices { span(.class("rc-pulse rc-p\(index + 1)")) {} }
                p(.class("rc-status")) {
                    for (index, status) in statuses.enumerated() { span(.class("rc-st\(index + 1)")) { status } }
                }
            }
            figcaption {
                "The trip desk keeps its state in memory and appends every change to its journal. A crash loses the memory, not the journal: the trip desk restarts and replays it line by line, back to where it was."
            }
        }
    }
}

/// A small static figure, drawn in the brand's dot style.
struct Diagram: HTML {
    let label: String
    let svg: String

    var body: some HTML {
        figure(.class("diagram")) {
            HTMLRaw(svg)
            figcaption { label }
        }
    }

    /// An object survives a crash, told left to right: it writes each change to its journal, the process stops,
    /// and a new instance replays the journal and carries on with the same name and state.
}

/// The tech page's picture: a small core, with everything else orbiting it as objects, like planets round a sun.
/// It builds itself as the story is read. Each part of the story adds what it explains: the first objects, their
/// orbits and messages, their names, the agents, the behaviors, the permission ring, the product's boundary.
/// Things only ever appear, never leave, so there's no in-between state to land on. Each piece appears once,
/// on its own part's scroll timeline. Rings turn with CSS, labels counter-turn to stay upright, and pulses
/// travel the spokes as SVG animation.
struct Orbit: HTML {
    private struct Planet {
        let name: String
        let note: String
        let degrees: Double
        let tone: Tone
    }

    /// One orbit, and the parts of the story that bring in its planets, their names, and their path and spokes.
    private struct Ring {
        let radius: Double
        let seconds: Int
        let clockwise: Bool
        let planets: [Planet]
        let planetsAppear: TechTopic
        let namesAppear: TechTopic
        let pathAppears: TechTopic
        /// Small rockets flying between two of this ring's planets, the way Hail's agents hail each other across space.
        var rockets: [Rocket] = []
    }

    private struct Rocket {
        let from: Int
        let to: Int
        let seconds: Double
        let appears: TechTopic
        /// How far the arc bends, as a share of the ring's radius: below 1 inside the ring, above 1 outside it.
        var bend: Double = 0.72
    }

    private static let centre = Point(x: 500, y: 500)

    private static let rings: [Ring] = [
        Ring(
            radius: 400, seconds: 160, clockwise: true,
            planets: [
                Planet(name: "your app", note: "API", degrees: 60, tone: .ink),
                Planet(name: "flights", note: "supplier", degrees: 170, tone: .ink),
                Planet(name: "traveller", note: "Telegram", degrees: 290, tone: .ink),
            ], planetsAppear: .objects, namesAppear: .actors, pathAppears: .actors,
            rockets: [Rocket(from: 2, to: 0, seconds: 16, appears: .actors)]),
        Ring(
            radius: 170, seconds: 70, clockwise: true,
            planets: [
                Planet(name: "concierge", note: "agent", degrees: 205, tone: .message),
                Planet(name: "planner", note: "agent", degrees: 25, tone: .message),
            ], planetsAppear: .agents, namesAppear: .agents, pathAppears: .agents,
            rockets: [Rocket(from: 0, to: 1, seconds: 12, appears: .agents, bend: 1.45)]),
        Ring(
            radius: 285, seconds: 110, clockwise: false,
            planets: [
                Planet(name: "trip desk", note: "rule", degrees: 115, tone: .life),
                Planet(name: "group tours", note: "behavior", degrees: 250, tone: .life),
                Planet(name: "rebooking", note: "behavior", degrees: 345, tone: .life),
            ], planetsAppear: .behaviors, namesAppear: .behaviors, pathAppears: .behaviors,
            rockets: [Rocket(from: 0, to: 1, seconds: 20, appears: .behaviors)]),
    ]

    /// Layers, bottom to top: the paths and the product boundary; one layer per ring, which the GPU turns whole
    /// (its spokes, pulses and rockets drawn in it, its planets and their names as HTML on it); then the
    /// permission ring and the core. Turning a ring this way redraws nothing: inside a single SVG it would
    /// redraw the whole picture every frame.
    var body: some HTML {
        div(.class("orbit"), .init(name: "aria-hidden", value: "true")) {
            HTMLRaw(Self.svg(Self.below))
            for ring in Self.rings { HTMLRaw(Self.layer(for: ring)) }
            HTMLRaw(Self.svg(Self.above))
        }
    }

    private static func svg(_ content: String) -> String {
        "<svg class=\"orbit-drawing\" viewBox=\"-40 -40 1080 1080\">\(content)</svg>"
    }

    /// A point of the drawing as a share of the orbit's box, so HTML placed there scales with the picture.
    private static func percent(_ point: Point) -> (String, String) {
        (String(format: "%.2f%%", (point.x + 40) / 10.8), String(format: "%.2f%%", (point.y + 40) / 10.8))
    }

    /// Each part of the story names a scroll timeline; everything the orbit adds for it follows that timeline.
    /// The selectors outrank `.orbit .appear`, whose `animation` shorthand would otherwise reset the timeline.
    static var css: String {
        // the parts' timelines, and the night's, which the top bar follows
        let names = (TechTopic.allCases.map { "--t-\($0.rawValue)" } + ["--t-night"]).joined(separator: ", ")
        return "body { timeline-scope: \(names); }\n"
            + TechTopic.allCases.map { ".orbit .appear.a-\($0.rawValue) { animation-timeline: --t-\($0.rawValue); }" }
            .joined(separator: "\n")
    }

    private static func appear(_ step: TechTopic, _ content: String) -> String {
        "<g class=\"appear a-\(step.rawValue)\">\(content)</g>"
    }

    /// A tiny rocket that leaves one planet, flies an arc inside the ring to another, fades out and starts again.
    /// It lives in the ring's group, so it turns with the ring and always flies between the same two planets.
    private static func rocket(on ring: Ring, _ rocket: Rocket) -> String {
        let c = centre
        func point(_ degrees: Double, _ radius: Double) -> Point {
            Point(x: c.x + radius * cos(degrees * .pi / 180), y: c.y + radius * sin(degrees * .pi / 180))
        }
        let a = ring.planets[rocket.from].degrees
        let b = ring.planets[rocket.to].degrees
        var middle = (a + b) / 2
        if abs(b - a) > 180 { middle += 180 }
        let start = point(a, ring.radius)
        let end = point(b, ring.radius)
        let bend = point(middle, ring.radius * rocket.bend)
        let f = { (v: Double) in String(format: "%.1f", v) }
        let path = "M\(f(start.x)) \(f(start.y))Q\(f(bend.x)) \(f(bend.y)) \(f(end.x)) \(f(end.y))"
        let timing = "dur=\"\(rocket.seconds)s\" repeatCount=\"indefinite\""
        let ship =
            "<path class=\"rocket-flame\" d=\"M-15 -4L-28 0L-15 4Z\"/>"
            + "<path class=\"rocket-fin\" d=\"M-9 -6L-18 -14L-15 -5ZM-9 6L-18 14L-15 5Z\"/>"
            + "<path class=\"rocket-body\" d=\"M18 0C10 -9 -8 -9 -15 -6L-15 6C-8 9 10 9 18 0Z\"/>"
            + "<circle class=\"rocket-window\" cx=\"5\" cy=\"0\" r=\"3.4\"/>"
        return appear(
            rocket.appears,
            "<g class=\"motion\"><g opacity=\"0\">\(ship)"
                + "<animateMotion \(timing) path=\"\(path)\" rotate=\"auto\" keyPoints=\"0;1;1\" keyTimes=\"0;0.75;1\" calcMode=\"linear\"/>"
                + "<animate attributeName=\"opacity\" values=\"0;1;1;0;0\" keyTimes=\"0;0.06;0.68;0.75;1\" \(timing)/></g></g>"
        )
    }

    private static func position(of planet: Planet, on ring: Ring) -> Point {
        let angle = planet.degrees * .pi / 180
        return Point(x: centre.x + ring.radius * cos(angle), y: centre.y + ring.radius * sin(angle))
    }

    /// One ring as its own layer: the GPU turns it; its planets' names turn back so they stay upright.
    private static func layer(for ring: Ring) -> String {
        let c = centre
        let index = rings.firstIndex { $0.radius == ring.radius } ?? 0
        let direction = ring.clockwise ? "normal" : "reverse"
        let back = ring.clockwise ? "reverse" : "normal"
        let lines =
            ring.planets.enumerated().map { offset, planet in
                let at = position(of: planet, on: ring)
                let x = String(format: "%.1f", at.x)
                let y = String(format: "%.1f", at.y)
                let lead = String(format: "%.1f", Double(index) * 0.7 + Double(offset) * 0.9)
                return appear(
                    ring.pathAppears,
                    "<line class=\"spoke\" x1=\"\(c.x)\" y1=\"\(c.y)\" x2=\"\(x)\" y2=\"\(y)\"/>"
                        + "<g class=\"motion\"><circle class=\"pulse\" r=\"6\"><animateMotion dur=\"2.6s\" begin=\"-\(lead)s\" repeatCount=\"indefinite\" path=\"M\(c.x) \(c.y)L\(x) \(y)\"/></circle></g>"
                )
            }.joined() + ring.rockets.map { rocket(on: ring, $0) }.joined()
        let planets = ring.planets.map { planet in
            let (left, top) = percent(position(of: planet, on: ring))
            return "<div class=\"planet appear a-\(ring.planetsAppear.rawValue)\" style=\"left:\(left);top:\(top)\">"
                + "<span class=\"dot t-\(planet.tone.rawValue)\"></span>"
                + "<div class=\"upright\" style=\"animation-duration:\(ring.seconds)s;animation-direction:\(back)\">"
                + "<div class=\"names appear a-\(ring.namesAppear.rawValue)\"><b>\(planet.name.escapedForMarkup)</b><i>\(planet.note.escapedForMarkup)</i></div>"
                + "</div></div>"
        }.joined()
        return "<div class=\"ring\" style=\"animation-duration:\(ring.seconds)s;animation-direction:\(direction)\">"
            + svg(lines) + planets + "</div>"
    }

    /// Under the rings: each ring's path, and the product's boundary round everything.
    private static var below: String {
        let c = centre
        let paths = rings.map {
            appear($0.pathAppears, "<circle class=\"path\" cx=\"\(c.x)\" cy=\"\(c.y)\" r=\"\($0.radius)\"/>")
        }.joined()
        let product = appear(
            .plugins,
            "<circle class=\"boundary\" cx=\"\(c.x)\" cy=\"\(c.y)\" r=\"488\"/>"
                + "<text class=\"boundary-label\" x=\"\(c.x)\" y=\"\(c.y - 500)\">your product</text>")
        return product + paths
    }

    /// Over the rings: the permission ring every action passes on the way in, and the core.
    private static var above: String {
        let c = centre
        let permissions = appear(
            .effects,
            "<circle class=\"gate\" cx=\"\(c.x)\" cy=\"\(c.y)\" r=\"104\"/>"
                + "<text class=\"gate-label\" x=\"\(c.x)\" y=\"\(c.y - 116)\">permissions</text>")
        let core =
            "<circle class=\"halo\" cx=\"\(c.x)\" cy=\"\(c.y)\" r=\"78\"/>"
            + "<g class=\"motion\"><circle class=\"flare\" cx=\"\(c.x)\" cy=\"\(c.y)\" r=\"52\">"
            + "<animate attributeName=\"r\" values=\"52;120;120\" keyTimes=\"0;0.6;1\" dur=\"3.2s\" repeatCount=\"indefinite\"/>"
            + "<animate attributeName=\"opacity\" values=\"0.7;0;0\" keyTimes=\"0;0.6;1\" dur=\"3.2s\" repeatCount=\"indefinite\"/></circle></g>"
            + "<circle class=\"core\" cx=\"\(c.x)\" cy=\"\(c.y)\" r=\"52\"/>"
            + "<text class=\"core-label\" x=\"\(c.x)\" y=\"\(c.y + 8)\">core</text>"
        return permissions + core
    }
}
