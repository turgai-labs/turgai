import DiscoverableActors
import DistributedCluster
import Foundation
import Hail
import TurgaiApplication
import TurgaiObjects

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
        /// The demo shop is there from the start. The request is the first turn, and these turns
        /// follow it in the same conversation; after each, customers ask the shop for refunds,
        /// which the managers on duty must decide as asked.
        case shop([ShopTurn])
        /// One turn, in which the agent asks `agent`, and its answer must say what that agent said.
        case asks(agent: String, answered: @Sendable (String) -> Bool)
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

    init(request: String, agents: [EvalAgent] = [], check: Check) {
        self.request = request
        self.agents = agents
        self.check = check
    }

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
            request: ShopTurn.all[0].prompt,
            check: .shop(ShopTurn.all)),
        EvalTask(
            request: "Ask the planner what I should do first on Saturday, and tell me.",
            agents: [planner],
            check: .asks(agent: "planner", answered: has("coffee"))),
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
        case .shop:
            return true
        case .asks(let agent, let answered):
            // Its tool, by the agent's id, whichever way tools are named: `planner_respond`,
            // `object_planner_respond`.
            let asked: Bool = turns.flatMap(\.calls).contains { (call: RecordedTurn.Call) -> Bool in
                call.name.hasSuffix("\(agent)_respond") && call.completed && !call.failed
            }
            return asked && turns.last.map { (turn: RecordedTurn) -> Bool in answered(turn.answer) } == true
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
        let session = ObjectSession(actorSystem: node.system, objectCatalog: node.objectCatalog)
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
        let directory = try await DynamicObjects.resolve(on: system)
        var saved: [String] = []
        for handle in created {
            guard let object = try? await directory.existing(ObjectIdentity(rawValue: handle)),
                let code = try? await object.source.code
            else { continue }
            saved.append("\(handle):\n\(code)")
        }
        return saved.isEmpty ? nil : saved.joined(separator: "\n\n")
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
        var turnChecks: [String?] = []
        var stateText = ""
        // Everything the eval does, it does as the person asking.
        do {
            try await CallChain.$current.withValue(.start(EvalNode.asker)) {
                let node = try await EvalNode.start(
                    model: model, temperature: temperature, instructions: instructions,
                    objectsPageDescription: objectsPageDescription, agents: agents)
                defer { node.stop() }
                switch check {
                case .followUp(let followUp, let stateAddresses, _, _):
                    let asked = try await followingUp(with: followUp, readingStateOf: stateAddresses, on: node)
                    turns = asked.turns
                    stateText = asked.stateText
                    failure = asked.missing
                case .asks:
                    let agent = try await node.freshAgent()
                    turns.append(await RecordedTurn.send(request, to: agent, on: node.system))
                case .shop(let shopTurns):
                    let floor = try await ShopFloor(on: node.system)
                    let agent = try await node.freshAgent()
                    for turn in shopTurns {
                        turns.append(await RecordedTurn.send(turn.prompt, to: agent, on: node.system))
                        turnChecks.append(try await turn.check(floor))
                    }
                }
            }
        } catch {
            failure = String(describing: error)
        }
        let followUpTurn = turns.dropFirst(1 + then.count).first
        let replies: [String] = Self.replies(in: followUpTurn)
        // A turn whose refunds went otherwise than asked is why the run failed, unless it failed before.
        let turnFailures: [String?] = turns.map(\.failure)
        failure = failure ?? Self.firstFailure(in: turnFailures) ?? Self.firstFailure(in: turnChecks)
        let passed: Bool = failure == nil && passes(turns: turns, replies: replies, stateText: stateText)
        let marks = turnChecks.isEmpty ? "" : "turns " + turnChecks.map { $0 == nil ? "✓" : "✗" }.joined() + "  "
        // Why it failed, in a line: the error, or the state the objects ended in and the reply.
        var why = failure
        if why == nil, !passed, case .followUp(_, _, let answered, let stateMatches) = check {
            var parts: [String] = []
            if !stateMatches(stateText) { parts.append("state: \(Self.inOneLine(stateText).prefix(100))") }
            if !replies.contains(where: answered) {
                parts.append("reply: \((followUpTurn?.answer ?? "").replacingOccurrences(of: "\n", with: " ").prefix(80))")
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
                "\(passed ? "PASS" : "FAIL")  \(Int(Date().timeIntervalSince(started)))s  \(marks)\(request.prefix(45))\(note)\(noticed)",
            transcript: (failure.map { "failed: \($0)\n" } ?? "")
                + turns.enumerated().map { index, turn in
                    "=== turn \(index + 1)\n" + turn.transcript
                        + (turnChecks.indices.contains(index) ? "=== check: \(turnChecks[index] ?? "PASS")\n" : "")
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

/// A customer of the demo shop, told how their refunds end.
@Discoverable
distributed actor EvalCustomer {
    typealias ActorSystem = ClusterSystem

    init(actorSystem: ActorSystem) {
        self.actorSystem = actorSystem
    }

    /// Your refund was paid out.
    /// - Parameter number: The order's number.
    distributed func refunded(number: Int) {}

    /// Your refund was refused.
    /// - Parameter number: The order's number.
    distributed func refundDenied(number: Int) {}
}

/// One turn of the shop task: what's asked, and how the shop's refunds must go after it.
struct ShopTurn: Sendable {
    let prompt: String
    /// What went wrong, or `nil` when the shop's refunds went as asked.
    let check: @Sendable (ShopFloor) async throws -> String?

    static let all = [
        // Managers on duty take refunds in turn, so whichever started first, 15 is approved, and
        // of the 40s Ann approves one and Bob keeps the other.
        ShopTurn(
            prompt:
                "I need two refund managers for the shop, Ann and Bob. They can approve small refunds on their own — Ann up to 50, Bob up to 20 — and keep anything bigger for me to decide later. Put them both on shift.",
            check: { floor in
                guard try await floor.managers.count == 2 else {
                    return "\(try await floor.managers.count) managers on duty, not 2"
                }
                return try await floor.refunds(
                    of: [15, 40, 40],
                    endingAs: [[.refunded, .refundRequested, .refunded], [.refunded, .refunded, .refundRequested]])
            }),
        // One refund of 300 goes to each: Ann denies hers, Bob keeps his.
        ShopTurn(
            prompt: "Ann should deny any refund over 200 straight away.",
            check: { floor in
                try await floor.refunds(
                    of: [300, 300], endingAs: [[.refundDenied, .refundRequested], [.refundRequested, .refundDenied]])
            }),
        // A counter doesn't take what the shop sends a manager, so it can't go on shift.
        ShopTurn(
            prompt: "Make a coffee counter I can add cups to, and put it on shift at the shop too.",
            check: { floor in
                let managers = try await floor.managers.count
                return managers == 2 ? nil : "\(managers) managers on duty, not 2"
            }),
        // Both count, being the same behavior: each approves one of two small refunds.
        ShopTurn(
            prompt: "Ann and Bob should also count how many refunds they approved.",
            check: { floor in
                let before = try await floor.managerNumbers()
                if let wrong = try await floor.refunds(of: [10, 10], endingAs: [[.refunded, .refunded]]) {
                    return wrong
                }
                let after = try await floor.managerNumbers()
                for (manager, numbers) in after {
                    let counted = numbers.contains { name, value in value == (before[manager]?[name] ?? 0) + 1 }
                    guard counted else { return "\(manager) counted nothing: \(numbers)" }
                }
                return nil
            }),
    ]
}

/// The demo shop and a customer of it, for checking how refunds go.
struct ShopFloor: Sendable {
    let demo: DemoObjects
    let customer: EvalCustomer
    let replyTo: DiscoverableObject

    init(on system: ClusterSystem) async throws {
        demo = try await DemoObjects(actorSystem: system)
        customer = EvalCustomer(actorSystem: system)
        replyTo = try DiscoverableObject.resolve(id: customer.id, using: system)
    }

    var managers: [DynamicObject] {
        get async throws { try await demo.shop.managers }
    }

    /// New orders of `amounts`, each refund asked for; `nil` once their statuses are one of
    /// `endings`, or what they are instead after ten seconds.
    func refunds(of amounts: [Decimal], endingAs endings: [[ShopOrderStatus]]) async throws -> String? {
        let first = try await demo.shop.orders.count + 1
        for amount in amounts { _ = try await demo.shop.placeOrder(item: "Lamp", amount: amount) }
        for number in first..<(first + amounts.count) {
            _ = try await demo.shop.requestRefund(number: number, replyTo: replyTo)
        }
        func statuses() async throws -> [ShopOrderStatus] {
            try await demo.shop.orders.dropFirst(first - 1).map(\.status)
        }
        for _ in 0..<50 {
            if endings.contains(try await statuses()) { return nil }
            try await Task.sleep(for: .milliseconds(200))
        }
        return "refunds of \(amounts) ended as \(try await statuses().map(\.rawValue))"
    }

    /// Each manager's numbers, by name, by manager.
    func managerNumbers() async throws -> [String: [String: Double]] {
        var numbers: [String: [String: Double]] = [:]
        for manager in try await managers {
            let description = try await manager.describe()
            let id = DynamicObject.identity(of: manager.id)?.rawValue ?? description.type
            // A manager holding no numbers is listed too, so it's checked like the others.
            numbers[id] = [:]
            for name in description.properties.keys {
                switch try await manager.read(property: name) {
                case .integer(let value): numbers[id, default: [:]][name] = Double(value)
                case .number(let value): numbers[id, default: [:]][name] = value
                default: break
                }
            }
        }
        return numbers
    }
}

/// Read by everyone and written by no one, as a built-in object.
extension EvalCustomer: AccessControlled {
    func access(for chain: CallChain) -> ObjectAccess { .readByEveryone }
}
