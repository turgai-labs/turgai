import DiscoverableActors
import DistributedCluster
import Foundation
import Hail
import TurgaiApplication
import TurgaiCalls
import TurgaiDomain
import TurgaiObjects
import TurgaiSpaces

/// Something to ask for, and how to tell it was done.
struct EvalTask: Sendable {
    let request: String
    /// Requests that follow it, one turn each, before the check: what a person asks for one
    /// object at a time.
    var then: [String] = []
    /// The agents there are, besides the one asked: each can be asked as an object.
    var agents: [EvalAgent] = []
    let check: Check

    enum Check: Sendable {
        /// A second turn asks this, and an object's reply must answer it.
        case followUp(
            String, stateAddresses: [String], answered: @Sendable (String) -> Bool,
            stateMatches: @Sendable (String) -> Bool)
        /// One turn, in which the agent asks `agent`, and its answer must say what that agent said.
        case asks(agent: String, answered: @Sendable (String) -> Bool)
        /// The request makes an object, and what follows shares it: who may use it then must pass
        /// `allowed`.
        case shared(allowed: @Sendable (Access) -> Bool)
        /// One turn, in which the agent sends HTTP requests itself, and its answer must say what
        /// came back.
        case sends(answered: @Sendable (String) -> Bool)
    }

    init(
        request: String, then: [String] = [], agents: [EvalAgent] = [], followUp: String, stateAddress: String? = nil,
        stateAddresses: [String] = [],
        stateMatches: @escaping @Sendable (String) -> Bool = { _ in false },
        answered: @escaping @Sendable (String) -> Bool
    ) {
        self.request = request
        self.then = then
        self.agents = agents
        self.check = .followUp(
            followUp, stateAddresses: stateAddresses + (stateAddress.map { [$0] } ?? []),
            answered: answered, stateMatches: stateMatches)
    }

    init(request: String, then: [String] = [], agents: [EvalAgent] = [], check: Check) {
        self.request = request
        self.then = then
        self.agents = agents
        self.check = check
    }

    /// Someone else in the eval's chat, and someone outside it: whom sharing with the chat lets in,
    /// and whom it doesn't.
    private static let inTheChat = CallScope(
        .account(UUID()), in: EvalNode.space, may: .members, groups: [.members], allowed: [])
    private static let outside = CallScope(
        .account(UUID()), in: SpaceID(), may: .members, groups: [.members], allowed: [])

    /// A planner, whose every plan starts the same way, so an answer can be told to be its.
    private static let planner = EvalAgent(
        role: Role("planner"),
        instructions: "You plan people's days. Every plan you give starts with coffee at nine.")

    static let all: [EvalTask] = [
        EvalTask(
            request: "Make a counter for my coffee cups: I can add a cup, ask how many I had, and reset it.",
            followUp: "Add two cups and check how many there are.", stateAddress: "coffee-cup-counter",
            stateMatches: { $0.range(of: #"(?m)^\w+:\s*2(?:\.0)?$"#, options: .regularExpression) != nil },
            answered: has("2")),
        EvalTask(
            request: "Make a shopping list I can add things to, cross things off, and ask what's still on it.",
            followUp: "Put milk and eggs on it, then cross off milk. What's still on it?",
            stateAddress: "shopping-list",
            // What's still on it, in its state: milk is crossed off, either gone or marked so.
            stateMatches: { Self.itemsLeft(in: $0) == ["eggs"] },
            // The answer says what's on it.
            answered: { $0.lowercased().contains("egg") }),
        EvalTask(
            request: "Make a counter for my coffee cups: I can add a cup and ask how many I had.",
            then: ["Change the coffee counter so I can also take a cup back."],
            followUp: "Add two cups and take one back. How many cups now?",
            stateMatches: { $0.range(of: #"(?m)^\w+:\s*1(?:\.0)?$"#, options: .regularExpression) != nil },
            answered: has("1")),
        EvalTask(
            request: "Make a shopping list I can add things to and cross things off.",
            then: ["Let everyone in this chat use the shopping list."],
            check: .shared { access in access.allows(inTheChat, .read) && !access.allows(outside, .read) }),
        EvalTask(
            request: "Make two counters, one for coffee and one for tea, that work the same way.",
            followUp: "Count one coffee and two teas. How many teas so far?",
            stateAddresses: ["coffee-counter", "tea-counter"],
            // The data's names are the code's own: one holds 1, the other 2, directly or in an
            // object it holds (`counter: a `Counter` holding value: 1`).
            stateMatches: { text in
                let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
                func holds(_ count: Int) -> Bool {
                    lines.contains {
                        $0.range(
                            of: #"(?:^|[\s,])\w+:\s*"# + "\(count)" + #"(?:\.0)?(?:$|[,;\s])"#,
                            options: .regularExpression) != nil
                    }
                }
                return holds(1) && holds(2)
            }, answered: has("2")),
        EvalTask(
            request:
                "Make a manager, Ann, with a budget of 1000. When she's asked for a raise of some amount, she approves it if her budget covers it, and the amount is taken out of her budget.",
            then: [
                "Make a worker, Bob, earning 3000. He asks Ann for a raise by giving her the amount he wants; when she approves, that amount is added to his pay.",
                "Bob asks Ann for a raise of 200.",
            ],
            followUp: "What does Bob earn now?", stateAddresses: ["ann", "bob"],
            // Bob earns 3200, and Ann paid it: her budget is down to 800.
            stateMatches: { state in
                [3200, 800].allSatisfy { amount in
                    state.range(of: #"(?m)^\s*\w+:\s*"# + "\(amount)" + #"(?:\.0)?$"#, options: .regularExpression)
                        != nil
                }
            },
            answered: has("3200")),
        EvalTask(
            request: "Ask the planner what I should do first on Saturday, and tell me.",
            agents: [planner],
            check: .asks(agent: "planner", answered: has("coffee"))),
        EvalTask(
            request: "What's the heading of the page at https://example.com?",
            check: .sends(answered: has("example domain"))),
        EvalTask(
            request:
                "Ask https://httpbin.org/headers with the header X-Turgai-Check set to blue-kettle, and tell me what it says that header was.",
            check: .sends(answered: has("blue-kettle"))),
        EvalTask(
            request:
                #"Post the JSON {"name": "Ann", "cups": 3} to https://httpbin.org/post and tell me what JSON it says it got."#,
            check: .sends(answered: has("ann", "3"))),
        EvalTask(
            request:
                "Make a day planner that, when I ask it for a plan, asks the planner agent for one and keeps the latest plan.",
            agents: [planner],
            followUp: "Get me a plan for Saturday. What's first on it?",
            stateMatches: { $0.lowercased().contains("coffee") },
            answered: has("coffee")),
    ]

    private static func has(_ words: String...) -> @Sendable (String) -> Bool {
        { reply in words.allSatisfy { reply.lowercased().contains($0) } }
    }

    struct Result {
        let passed: Bool
        let line: String
        let transcript: String
    }

    /// What the follow-up got back from the objects: each of their own replies, from one of their
    /// actions or values, such as `coffee-counter_howMany`, and the turn's answer. Not searching,
    /// creating, a page (named by the bare handle), or changing an object.
    private static func replies(in followUpTurn: RecordedTurn?) -> [String] {
        guard let followUpTurn else { return [] }
        let notReplies: Set<String> = [
            "search_objects", "create_object", "create_object_like", "edit_object", "remove_object", "use_object",
        ]
        let own: [RecordedTurn.Call] = followUpTurn.calls.filter { (call: RecordedTurn.Call) -> Bool in
            call.completed && !call.failed && call.name.contains("_") && !notReplies.contains(call.name)
        }
        return own.map(\.output) + [followUpTurn.answer]
    }

    /// Whether the run did what its check asks, once nothing failed.
    private func passes(turns: [RecordedTurn], replies: [String], stateText: String) -> Bool {
        switch check {
        case .followUp(_, _, let answered, let stateMatches):
            return replies.contains(where: answered) && stateMatches(stateText)
        case .shared:
            return true
        case .asks(let agent, let answered):
            // Its tool, by the agent's id, whichever way tools are named: `planner_respond`,
            // `object_planner_respond`.
            let asked: Bool = turns.flatMap(\.calls).contains { (call: RecordedTurn.Call) -> Bool in
                call.name.hasSuffix("\(agent)_respond") && call.completed && !call.failed
            }
            return asked && turns.last.map { (turn: RecordedTurn) -> Bool in answered(turn.answer) } == true
        case .sends(let answered):
            let sent: Bool = turns.flatMap(\.calls).contains { (call: RecordedTurn.Call) -> Bool in
                call.name == "http_send" && call.completed && !call.failed
            }
            return sent && turns.last.map { (turn: RecordedTurn) -> Bool in answered(turn.answer) } == true
        }
    }

    /// `text`'s lines, trimmed, on one line.
    private static func inOneLine(_ text: String) -> String {
        text.split(separator: "\n").map { (line: Substring) -> String in line.trimmingCharacters(in: .whitespaces) }
            .filter { (line: String) -> Bool in !line.isEmpty }.joined(separator: " ")
    }

    /// The first turn's reason for failing, numbered from one, if any turn has one.
    private static func firstFailure(in reasons: [String?]) -> String? {
        reasons.enumerated().lazy.compactMap { (index: Int, reason: String?) -> String? in
            reason.map { (reason: String) -> String in "turn \(index + 1): \(reason)" }
        }.first
    }

    /// What each object at `addresses` holds now, as its page shows its current values; the first
    /// one missing, with what the request made instead.
    private static func state(of addresses: [String], created: [String], on node: EvalNode) async
        -> (text: String, missing: String?)
    {
        guard
            let session = try? await ObjectSession(
                in: EvalNode.space, actorSystem: node.system, agents: [], builtIns: [])
        else { return ("The eval's space isn't there.", nil) }
        let made: String = created.isEmpty ? "none" : created.joined(separator: ", ")
        var text = ""
        var missing: String?
        for address in addresses {
            let page: ToolPage
            do {
                page = try await session.open(ToolPageAddress(rawValue: address))
            } catch {
                text += "\(address): MISSING (created: \(made)).\n"
                missing =
                    missing ?? "Expected object `\(address)` is missing; created: \(made). Page lookup failed: \(error)"
                continue
            }
            text += "\(address):\n\(currentValues(on: page.output.textRepresentation))\n"
        }
        return (text, missing)
    }

    /// The current values a page shows: what's between its heading and its actions.
    private static func currentValues(on page: String) -> String {
        guard let range = page.range(of: "Current values:\n") else { return page }
        let values: Substring = page[range.upperBound...]
        return String(values.split(separator: "\n\nActions:", maxSplits: 1).first ?? values)
    }

    /// The code each of the `created` objects ended with, when any has code.
    private static func savedCode(of created: [String], on system: ClusterSystem) async throws -> String? {
        guard !created.isEmpty else { return nil }
        var saved: [String] = []
        for handle in created {
            // The object, by its id.
            guard
                let object = try? await DynamicObject.identified(
                    by: ObjectIdentity(rawValue: handle), in: EvalNode.space, on: system),
                let code = try? await object.source.code
            else { continue }
            saved.append("\(handle):\n\(code)")
        }
        return saved.isEmpty ? nil : saved.joined(separator: "\n\n")
    }

    /// The request and what follows it, asked of a fresh agent; then who may use the object the
    /// request made, which `allowed` must accept.
    private func sharing(checkedBy allowed: @Sendable (Access) -> Bool, on node: EvalNode) async throws
        -> (turns: [RecordedTurn], failure: String?)
    {
        let agent = try await node.freshAgent()
        var turns: [RecordedTurn] = []
        for asked in [request] + then {
            turns.append(await RecordedTurn.send(asked, to: agent, on: node.system))
        }
        guard let made = turns.flatMap(\.calls).compactMap(Self.createdHandle(from:)).first,
            let access = try? await DynamicObject.identified(
                by: ObjectIdentity(rawValue: made), in: EvalNode.space, on: node.system
            ).access
        else { return (turns, turns.compactMap(\.failure).first ?? "No object was made.") }
        turns.append(RecordedTurn(answer: "Who may use \(made): \(access.levels)"))
        return (turns, allowed(access) ? nil : "Shared otherwise than asked: \(access.levels)")
    }

    /// The request and what follows it, then the follow-up, asked of a fresh agent; then what the
    /// objects the request made hold, and the code they ended with.
    private func followingUp(with followUp: String, readingStateOf stateAddresses: [String], on node: EvalNode)
        async throws -> (turns: [RecordedTurn], stateText: String, missing: String?)
    {
        let agent = try await node.freshAgent()
        var turns: [RecordedTurn] = []
        for asked in [request] + then {
            turns.append(await RecordedTurn.send(asked, to: agent, on: node.system))
        }
        turns.append(await RecordedTurn.send(followUp, to: agent, on: node.system))
        // Successful object actions return a page landing with null tool output. Read the
        // object's actual state after the turn, so the eval measures what changed rather
        // than whether the action's output happened to contain the answer.
        // An object is named after the actor its code declares, so its state is read from
        // the objects the request created, whatever they're called.
        let handles: [String] = turns.flatMap(\.calls).compactMap(Self.createdHandle(from:))
        let created: [String] = Array(NSOrderedSet(array: handles)) as? [String] ?? []
        let addresses: [String] = created.isEmpty ? stateAddresses : created
        var stateText = ""
        var missing: String?
        if !addresses.isEmpty {
            let state = await Self.state(of: addresses, created: created, on: node)
            stateText = state.text
            missing = state.missing
            turns.append(RecordedTurn(answer: "Object state after the request:\n" + stateText))
        }
        // The code each made object ended with, to read when a run fails.
        if let saved = try await Self.savedCode(of: created, on: node.system) {
            turns.append(RecordedTurn(answer: "Saved code:\n" + saved))
        }
        return (turns, stateText, missing)
    }

    /// Asks a fresh agent on a fresh node, then the follow-up, and checks the objects' replies.
    func run(with model: AgentModel, temperature: Double, instructions: String, objectsPageDescription: String? = nil)
        async -> Result
    {
        let started = Date()
        var turns: [RecordedTurn] = []
        var failure: String?
        var stateText = ""
        do {
            let node = try await EvalNode.start(
                model: model, temperature: temperature, instructions: instructions,
                objectsPageDescription: objectsPageDescription, agents: agents,
                sendsRequests: { if case .sends = check { true } else { false } }())
            defer { node.stop() }
            // Everything the eval does, it does as the person asking.
            try await CallChain.$current.withValue(.start(try await node.asker(), in: nil)) {
                switch check {
                case .followUp(let followUp, let stateAddresses, _, _):
                    let asked = try await followingUp(with: followUp, readingStateOf: stateAddresses, on: node)
                    turns = asked.turns
                    stateText = asked.stateText
                    failure = asked.missing
                case .shared(let allowed):
                    let shared = try await sharing(checkedBy: allowed, on: node)
                    turns = shared.turns
                    failure = shared.failure
                case .asks, .sends:
                    let agent = try await node.freshAgent()
                    turns.append(await RecordedTurn.send(request, to: agent, on: node.system))
                }
            }
        } catch {
            failure = String(describing: error)
        }
        let followUpTurn = turns.dropFirst(1 + then.count).first
        let replies: [String] = Self.replies(in: followUpTurn)
        // A turn that failed is why the run failed, unless it failed before.
        let turnFailures: [String?] = turns.map(\.failure)
        failure = failure ?? Self.firstFailure(in: turnFailures)
        let passed: Bool = failure == nil && passes(turns: turns, replies: replies, stateText: stateText)
        // Why it failed, in a line: the error, or the state the objects ended in and the reply.
        var why = failure
        if why == nil, !passed, case .followUp(_, _, let answered, let stateMatches) = check {
            var parts: [String] = []
            if !stateMatches(stateText) { parts.append("state: \(Self.inOneLine(stateText).prefix(100))") }
            if !replies.contains(where: answered) {
                parts.append(
                    "reply: \((followUpTurn?.answer ?? "").replacingOccurrences(of: "\n", with: " ").prefix(80))")
            }
            why = parts.joined(separator: "; ")
        }
        let note = why.map { "  (\($0.prefix(200)))" } ?? ""
        // What the runtime had to tell the model, each another request.
        let notices = turns.flatMap(\.notices)
        let noticed = notices.isEmpty ? "" : "  [noticed: \(notices.joined(separator: ", "))]"
        return Result(
            passed: passed,
            line:
                "\(passed ? "PASS" : "FAIL")  \(Int(Date().timeIntervalSince(started)))s  \(request.prefix(45))\(note)\(noticed)",
            transcript: (failure.map { "failed: \($0)\n" } ?? "")
                + turns.enumerated().map { index, turn in
                    "=== turn \(index + 1)\n" + turn.transcript
                }.joined()
        )
    }

    /// What's still on a list in an object's state, as its items are written: each one not
    /// crossed off, by its name. One is crossed off when it's gone, or holds a flag that's true.
    static func itemsLeft(in text: String) -> [String] {
        // Each item: its indentation, and its fields; a plain one is its own name.
        var items: [(indent: Int, fields: [String: String])] = []
        for raw in text.split(separator: "\n") {
            let indent = raw.prefix { $0 == " " }.count
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("- ") {
                items.append((indent, [:]))
                line = String(line.dropFirst(2))
            } else if let last = items.last, indent <= last.indent {
                continue
            }
            guard !items.isEmpty else { continue }
            if let colon = line.firstIndex(of: ":") {
                let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces).trimmingCharacters(
                    in: CharacterSet(charactersIn: "'\""))
                items[items.count - 1].fields[key] = value.lowercased()
            } else {
                items[items.count - 1].fields[""] = line.lowercased()
            }
        }
        return items.compactMap { item in
            guard !item.fields.values.contains("true") else { return nil }
            let names = ["", "name", "item", "title", "text"].compactMap { item.fields[$0] }
            return names.first { !$0.isEmpty }
        }
    }

    private static func createdHandle(from call: RecordedTurn.Call) -> String? {
        guard call.completed, !call.failed else { return nil }
        let marker: String
        switch call.name {
        case "create_object": marker = "Saved "
        default: return nil
        }
        guard let range = call.output.range(of: marker),
            let word = call.output[range.upperBound...].split(whereSeparator: \.isWhitespace).first
        else { return nil }
        return String(word).trimmingCharacters(in: CharacterSet(charactersIn: ".:,`"))
    }
}
