import DiscoverableActors
import DistributedCluster
import Foundation
import Hail
import TurgaiApplication
import TurgaiObjects

/// Something to ask for, and how to tell it was done.
struct EvalTask: Sendable {
    let request: String
    let check: Check
    /// How many distinct objects the request asks the model to make usable.
    let expectedObjects: Int
    let expectedUsableObjects: Int

    enum Check: Sendable {
        /// A second turn asks this, and an object's reply must answer it.
        case followUp(String, stateAddresses: [String], answered: @Sendable (String) -> Bool,
                      stateMatches: @Sendable (String) -> Bool)
        /// The demo shop is there from the start. The request is the first turn, and these turns
        /// follow it in the same conversation; after each, customers ask the shop for refunds,
        /// which the managers on duty must decide as asked.
        case shop([ShopTurn])
    }

    init(
        request: String, followUp: String, stateAddress: String? = nil, stateAddresses: [String] = [],
        expectedObjects: Int = 1, expectedUsableObjects: Int = 1,
        stateMatches: @escaping @Sendable (String) -> Bool = { _ in false },
        answered: @escaping @Sendable (String) -> Bool
    ) {
        self.request = request
        self.check = .followUp(
            followUp, stateAddresses: stateAddresses + (stateAddress.map { [$0] } ?? []),
            answered: answered, stateMatches: stateMatches)
        self.expectedObjects = expectedObjects
        self.expectedUsableObjects = expectedUsableObjects
    }

    init(request: String, expectedObjects: Int, expectedUsableObjects: Int, check: Check) {
        self.request = request
        self.check = check
        self.expectedObjects = expectedObjects
        self.expectedUsableObjects = expectedUsableObjects
    }

    static let all = [
        EvalTask(
            request: "Make a counter for my coffee cups: I can add a cup, ask how many I had, and reset it.",
            followUp: "I had two cups just now. How many have I had?", stateAddress: "coffee-cup-counter",
            stateMatches: { $0.range(of: #"(?m)^\w+:\s*2(?:\.0)?$"#, options: .regularExpression) != nil },
            answered: has("2")),
        EvalTask(
            request: "Make a shopping list I can add things to, cross things off, and ask what's still on it.",
            followUp: "Put milk and eggs on it, then cross off milk. What's still on it?",
            stateAddress: "shopping-list",
            stateMatches: { Self.bulletItems(in: $0) == ["eggs"] },
            answered: { $0.lowercased().contains("egg") && !$0.lowercased().contains("milk") }),
        EvalTask(
            request: "Make two counters, one for coffee and one for tea, that work the same way.",
            followUp: "Count one coffee and two teas. How many teas so far?", stateAddresses: ["coffee-counter", "tea-counter"],
            expectedObjects: 2, expectedUsableObjects: 2,
            stateMatches: { text in
                let lines = text.lowercased().components(separatedBy: .newlines)
                return lines.contains { $0.contains("count:") && $0.hasSuffix("1") }
                    && lines.contains { $0.contains("count:") && $0.hasSuffix("2") }
            }, answered: has("2")),
        EvalTask(
            request:
                "Make a manager, Ann, with a budget of 1000, and a worker, Bob, earning 3000. Bob can ask Ann for a raise, and she approves it while her budget lasts.",
            followUp: "Bob asks Ann for a raise of 200. What does Bob earn now?", stateAddresses: ["ann", "bob"],
            expectedObjects: 2, expectedUsableObjects: 2,
            stateMatches: { $0.range(of: #"(?m)^\w+:\s*3200(?:\.0)?$"#, options: .regularExpression) != nil },
            answered: has("3200")),
        EvalTask(
            request: ShopTurn.all[0].prompt, expectedObjects: 2, expectedUsableObjects: 2,
            check: .shop(ShopTurn.all)),
    ]

    private static func has(_ words: String...) -> @Sendable (String) -> Bool {
        { reply in words.allSatisfy { reply.lowercased().contains($0) } }
    }

    struct Result {
        let passed: Bool
        let stages: Stages
        let line: String
        let transcript: String
    }

    struct Stages: Sendable {
        let root: Bool
        let made: Bool
        let usable: Bool
        let opened: Bool
        let attempted: Bool
        let acted: Bool
        let state: Bool
        let outcome: Bool

        static let names = ["root", "made", "usable", "opened", "attempted", "acted", "state", "outcome"]
        var values: [Bool] { [root, made, usable, opened, attempted, acted, state, outcome] }
        var marks: String {
            zip(Self.names, values).map { name, value in "\(name):\(value ? "✓" : "✗")" }.joined(separator: " ")
        }
    }

    /// Asks a fresh agent on a fresh node, then the follow-up, and checks the objects' replies.
    func run(with model: AgentModel, temperature: Double, instructions: String, objectsPageDescription: String? = nil) async -> Result {
        let started = Date()
        var turns: [RecordedTurn] = []
        var failure: String?
        var turnChecks: [String?] = []
        var stateText = ""
        var usableCount = 0
        do {
            let node = try await EvalNode.start(model: model, temperature: temperature, instructions: instructions, objectsPageDescription: objectsPageDescription)
            defer { node.stop() }
            switch check {
            case .followUp(let followUp, let stateAddresses, _, _):
                let agent = try await node.freshAgent()
                turns.append(await RecordedTurn.send(request, to: agent, on: node.system))
                turns.append(await RecordedTurn.send(followUp, to: agent, on: node.system))
                // Successful object actions return a page landing with null tool output. Read the
                // object's actual state after the turn, so the eval measures what changed rather
                // than whether the action's output happened to contain the answer.
                if !stateAddresses.isEmpty {
                    let session = ObjectSession(actorSystem: node.system, objectCatalog: node.objectCatalog, scopes: [.shared])
                    for address in stateAddresses {
                        let page: Page
                        do {
                            page = try await session.open(PageAddress(rawValue: address))
                        } catch {
                            let created = (turns.first?.calls ?? []).compactMap(Self.createdHandle(from:))
                            stateText += "\(address): MISSING (created: \(created.isEmpty ? "none" : created.joined(separator: ", "))).\n"
                            failure = failure ?? "Expected object `\(address)` is missing; created: \(created.isEmpty ? "none" : created.joined(separator: ", ")). Page lookup failed: \(error)"
                            continue
                        }
                        let pageText = page.output.textRepresentation
                        let currentValues = pageText.range(of: "Current values:\n").map { range in
                            let values = pageText[range.upperBound...]
                            return String(values.split(separator: "\n\nActions:", maxSplits: 1).first ?? values)
                        } ?? pageText
                        stateText += "\(address):\n\(currentValues)\n"
                    }
                    turns.append(RecordedTurn(answer: "Object state after the request:\n" + stateText))
                }
            case .shop(let shopTurns):
                let floor = try await ShopFloor(on: node.system)
                let agent = try await node.freshAgent()
                for turn in shopTurns {
                    turns.append(await RecordedTurn.send(turn.prompt, to: agent, on: node.system))
                    turnChecks.append(try await turn.check(floor))
                }
            }
            let createdHandles = (turns.first?.calls ?? []).compactMap(Self.createdHandle(from:))
            let objectSession = ObjectSession(actorSystem: node.system, objectCatalog: node.objectCatalog, scopes: [.shared])
            for handle in Set(createdHandles) {
                guard let page = try? await objectSession.open(PageAddress(rawValue: handle)) else { continue }
                let hasActions = page.links.contains { link in
                    link.name.hasPrefix(handle + "_")
                        && !["_on", "_data", "_remove_event", "_set_value"].contains(where: link.name.hasSuffix)
                }
                if hasActions { usableCount += 1 }
            }
        } catch {
            failure = String(describing: error)
        }
        // An object's own reply, from one of its actions or its values, such as
        // `coffee-counter_howMany`: not from searching, creating, a page (named by the bare
        // handle), a draft's steps, or changing the object.
        let notReplies = ["search_objects", "create_object", "create_object_like", "edit_object", "remove_object", "use_object"]
        let notActions = ["_on", "_data", "_remove_event", "_set_value"]
        let followUpTurn = turns.dropFirst().first
        let replies = (followUpTurn?.calls ?? [])
            .filter { call in
                call.completed && !call.failed && call.name.contains("_") && !notReplies.contains(call.name)
                    && !notActions.contains(where: call.name.hasSuffix)
            }
            .map(\.output) + (followUpTurn.map { [$0.answer] } ?? [])
        // A turn whose refunds went otherwise than asked is why the run failed, unless it failed before.
        failure = failure ?? turns.enumerated().compactMap { index, turn in
            turn.failure.map { "turn \(index + 1): \($0)" }
        }.first
        failure = failure ?? turnChecks.enumerated().compactMap { index, why in why.map { "turn \(index + 1): \($0)" } }.first
        let passed =
            switch check {
            case .followUp(_, _, let answered, let stateMatches):
                failure == nil && replies.contains(where: answered) && stateMatches(stateText)
            case .shop: failure == nil
            }
        let calls = turns.flatMap(\.calls)
        let setupCalls = turns.first?.calls ?? []
        let made = setupCalls.filter {
            $0.completed && !$0.failed && ($0.name == "create_object" || $0.name == "create_object_like")
        }.count
        let definitionSuffixes = ["_on", "_data", "_remove_event", "_set_value"]
        let pageNames = Set(calls.compactMap { call -> String? in
            guard call.completed, !call.failed, !call.name.contains("_"), call.name != "objects",
                  call.output.hasPrefix("Opened ") else { return nil }
            return call.name
        })
        let actionCalls = turns.dropFirst().flatMap(\.calls).filter { call in
            call.completed && !call.failed && call.name.contains("_") && !notReplies.contains(call.name)
                && !definitionSuffixes.contains(where: call.name.hasSuffix)
        }
        let attemptedAction = turns.dropFirst().flatMap(\.calls).contains { call in
            call.name.contains("_") && !notReplies.contains(call.name)
                && !definitionSuffixes.contains(where: call.name.hasSuffix)
        }
        let stateOK: Bool = switch check {
        case .followUp(_, _, _, let stateMatches): stateMatches(stateText)
        case .shop: !turnChecks.isEmpty && turnChecks.allSatisfy { $0 == nil }
        }
        let stages = Stages(
            root: calls.contains { $0.completed && !$0.failed && $0.name == "objects" },
            made: made >= expectedObjects,
            usable: usableCount >= expectedUsableObjects,
            opened: !pageNames.isEmpty,
            attempted: attemptedAction,
            acted: !actionCalls.isEmpty,
            state: stateOK,
            outcome: passed)
        let marks = turnChecks.isEmpty ? "" : "turns " + turnChecks.map { $0 == nil ? "✓" : "✗" }.joined() + "  "
        let note = failure.map { "  (\($0.prefix(160)))" } ?? ""
        return Result(
            passed: passed,
            stages: stages,
            line:
                "\(passed ? "PASS" : "FAIL")  \(stages.marks)  \(marks)calls \(calls.count)  errors \(calls.filter(\.failed).count)  pending \(calls.filter { !$0.completed }.count)  context \(turns.map { $0.context.map { "\($0.usedTokens)" } ?? "?" }.joined(separator: "/"))  \(Int(Date().timeIntervalSince(started)))s  \(request.prefix(50))\(note)",
            transcript: "stages: \(stages.marks)\n" + (failure.map { "failed: \($0)\n" } ?? "")
                + turns.enumerated().map { index, turn in
                    "=== turn \(index + 1)\n" + turn.transcript
                        + (turnChecks.indices.contains(index) ? "=== check: \(turnChecks[index] ?? "PASS")\n" : "")
                }.joined()
        )
    }

    private static func bulletItems(in text: String) -> [String] {
        text.split(separator: "\n").compactMap { line in
            let line = line.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("- ") else { return nil }
            return String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces).lowercased()
        }
    }

    private static func createdHandle(from call: RecordedTurn.Call) -> String? {
        guard call.completed, !call.failed else { return nil }
        let marker: String
        switch call.name {
        case "create_object": marker = "Created empty "
        case "create_object_like": marker = "Made "
        default: return nil
        }
        guard let range = call.output.range(of: marker),
              let word = call.output[range.upperBound...].split(whereSeparator: \.isWhitespace).first else { return nil }
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
                guard try await floor.managers.count == 2 else { return "\(try await floor.managers.count) managers on duty, not 2" }
                return try await floor.refunds(
                    of: [15, 40, 40], endingAs: [[.refunded, .refundRequested, .refunded], [.refunded, .refunded, .refundRequested]])
            }),
        // One refund of 300 goes to each: Ann denies hers, Bob keeps his.
        ShopTurn(
            prompt: "Ann should deny any refund over 200 straight away.",
            check: { floor in
                try await floor.refunds(of: [300, 300], endingAs: [[.refundDenied, .refundRequested], [.refundRequested, .refundDenied]])
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
                if let wrong = try await floor.refunds(of: [10, 10], endingAs: [[.refunded, .refunded]]) { return wrong }
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
        for number in first..<(first + amounts.count) { _ = try await demo.shop.requestRefund(number: number, replyTo: replyTo) }
        func statuses() async throws -> [ShopOrderStatus] { try await demo.shop.orders.dropFirst(first - 1).map(\.status) }
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
            // A manager holding no numbers is listed too, so it's checked like the others.
            numbers[description.title] = [:]
            for name in description.properties.keys {
                switch try await manager.read(property: name) {
                case .integer(let value): numbers[description.title, default: [:]][name] = Double(value)
                case .number(let value): numbers[description.title, default: [:]][name] = value
                default: break
                }
            }
        }
        return numbers
    }
}
