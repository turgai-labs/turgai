import AnyLanguageModel
import Foundation
import Hail
import TurgaiAgents
import TurgaiApplication
import TurgaiObjects
import TurgaiPersistence
import TurgaiSpaces

/// What the object writer writes, first time, for an object that has to follow another object's
/// events: given the page as Swift declares it, with its button presses as a stream, and asked
/// for a counter of them. Nothing is checked or saved: each answer is FM's own first instinct.
enum WriterProbe {
    static let page = """
        - Page(id: "page")
          A page on this machine.
          Methods:
            show(_ layout: Layout)
          Events:
            ButtonPressed(label: String), received by onButtonPressed(_ buttonPressed: Page.ButtonPressed)
        """
    /// What events and subscribing are, then the calls for them, and where the receiving goes.
    static let events = """
        Events:
        An object can let others know when something happens to it. What happened is an event: a struct the object declares, holding what's worth knowing about it. Letting others know is announcing it, with announce(_:).
        Another object that wants to act when that happens subscribes to that kind of event, with subscribe(to:) on the object that announces it. From then on it receives every such event, one at a time, in the order they were announced, and acts on each one, for as long as it stays subscribed.
        Receiving never ends on its own, so it runs in a Task, and the method that subscribes returns.
        """
    /// The runtime's macro for following another object's events, declared as Swift declares one.
    static let macros = """
        Macros:
          @attached(peer) macro Subscribed(to object: Object)
            The method it's attached to is called with each event of that object named like the method.
        """
    static let request = "Count each press of the page's button."

    static func run(model: AgentModel, runs: Int, temperature: Double) async throws {
        let endpoints = AgentModelEndpointFactory(
            credentials: AgentCredentialStore(storage: .test),
            transports: ModelTransports(limits: RequestLimitStore.defaultLimits))
        let endpoint = try await endpoints.endpoint(
            model: model, configuration: try EvalNode.configuration(for: model), temperature: temperature)
        // Saved as the app saves: refused, with what's wrong at its code, until it's right.
        let writer = ObjectWriter(
            endpoint: endpoint, attempts: 4,
            report: { event in
                if case .answered = event { print(event.written) }
            })
        // The page, as the module the code imports declares it.
        let uses = Uses(
            interface: ModuleInterface(
                name: Uses.module,
                source:
                    "actor Page {\n    func show(_ layout: Layout)\n    @Event struct ButtonPressed: Codable {\n        var label: String\n    }\n}\n\nstruct Layout {\n    var items: [String]\n}"
            ),
            objects: [ObjectIdentity(rawValue: "page"): "Page"], lasting: ["Page"])
        var tally: [String: Int] = [:]
        var saved = 0
        for run in 1...runs {
            var final = ""
            // A request that fails, such as an answer running past the context, fails this run only.
            let outcome: ObjectWriter.Outcome
            do {
                outcome = try await writer.write(
                    type: "PressCounter", task: "Counts each press of the page's button.", current: nil,
                    others: [page], request: request
                ) { (code: String) -> String? in
                    do {
                        let script = try Script(code: code, type: "PressCounter", uses: uses)
                        let problems = await ScriptInstance.problems(in: script)
                        guard problems.isEmpty else {
                            return problems.map { $0.written(in: code) }.joined(separator: "\n")
                        }
                        _ = try ObjectShape(script)
                        final = code
                        return nil
                    } catch let problem as CodeProblem {
                        return problem.written(in: code)
                    } catch {
                        return "\(error)"
                    }
                }
            } catch {
                outcome = .failed("the request failed: \(error)")
            }
            let traits = Self.traits(of: final)
            // Saved and following the page: the subscription is what was asked for.
            if case .saved = outcome, traits.contains("follows page"),
                traits.contains("implements onButtonPressed(_:)")
            {
                saved += 1
            }
            for trait in traits { tally[trait, default: 0] += 1 }
            print("=== RUN \(run): \(outcome) \(traits.joined(separator: ", "))\n\(final)\n")
        }
        print("=== TALLY over \(runs) runs: \(saved) saved following the page")
        for (trait, count) in tally.sorted(by: { $0.key < $1.key }) { print("\(count)  \(trait)") }
    }

    /// What an answer does, by what's in its code.
    static func traits(of code: String) -> [String] {
        var traits: [String] = []
        if code.contains("for await") { traits.append("for await") }
        if code.contains("buttonPressed") { traits.append("uses buttonPressed") }
        if code.contains("Task {") || code.contains("Task{") { traits.append("Task") }
        if let initStart = code.range(of: "init()"), code[initStart.upperBound...].contains("for await"),
            let nextFunc = code.range(of: "func ", range: initStart.upperBound..<code.endIndex),
            code[initStart.upperBound..<nextFunc.lowerBound].contains("for await")
        {
            traits.append("loop in init")
        } else if code.contains("for await"),
            !code.contains("init()")
                || code.range(of: "init()").map({ !code[$0.upperBound...].prefix(400).contains("for await") }) == true
        {
            traits.append("loop in a method")
        }
        if code.contains("subscribe(to:") { traits.append("subscribe(to:)") }
        if code.range(
            of: #"@Subscribed\s+(private\s+)?var \w+ = Page\(id: "page"\)"#, options: .regularExpression) != nil
        {
            traits.append("follows page")
        }
        if code.contains("func onButtonPressed(_ buttonPressed: Page.ButtonPressed)") {
            traits.append("implements onButtonPressed(_:)")
        }
        if code.contains("onButtonPressed") || code.contains("handler") || code.contains("callback")
            || code.contains("subscribeTo")
        {
            traits.append("callback/subscribe invented")
        }
        return traits
    }
}

/// What FM makes of a layout, generated as the `@Generable` `Layout` it is, for a few asks.
enum PageProbe {
    static let asks = [
        "A layout titled Coffee, with two buttons side by side: Add and Reset.",
        "A layout with a heading, a short line of text under it, and a Buy button.",
        "A layout with two columns: Tea on the left with an Order button, Coffee on the right with an Order button.",
    ]

    static func run(model: AgentModel, runs: Int, temperature: Double) async throws {
        let endpoints = AgentModelEndpointFactory(
            credentials: AgentCredentialStore(storage: .test),
            transports: ModelTransports(limits: RequestLimitStore.defaultLimits))
        let endpoint = try await endpoints.endpoint(
            model: model, configuration: try EvalNode.configuration(for: model), temperature: temperature)
        for ask in asks {
            for run in 1...runs {
                let entries: [Transcript.Entry] = [.prompt(.init(segments: [.text(.init(content: ask))]))]
                let stream = endpoint.stream(
                    request: ModelRequest(input: entries, entries: entries), tools: [], authority: FullAuthority(),
                    generating: Layout.self, purpose: .generation)
                var result = "no page"
                for await event in stream {
                    switch event {
                    case .generated(let layout): result = String(describing: layout)
                    case .failed(let error): result = "failed: \(error)"
                    default: continue
                    }
                }
                print("=== \(ask) (run \(run))\n\(result)\n")
            }
        }
    }
}
