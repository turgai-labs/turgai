import ArgumentParser
import Foundation
import Hail
import Logging
import ServiceLifecycle

/// Measures how well a model makes and uses objects, through the app's own path: a Hail agent
/// with the app's object tools, making real objects. Each run asks for objects, then, in a second
/// turn to the same agent, uses them. A run passes when what it was asked comes back from an
/// object, not from the model's own reckoning. Nothing is kept between runs.
@main
struct ModelEval: AsyncParsableCommand {
    @Argument(help: "The model, such as ollama/qwen3.5:9b or system/default.")
    var model: String

    @Option(help: "Runs of each task.")
    var runs = 3

    @Option(help: "Where to write what each run did.")
    var log = "/tmp/turgai-model-eval.log"

    @Option(help: "The model's sampling temperature. Small models call tools more reliably near 0.")
    var temperature = 0.2

    @Option(help: "Only the tasks whose request contains this, ignoring case; repeat for more. All tasks without it.")
    var task: [String] = []

    @Option(
        help: "A file with the agent's instructions, as a profile's would be. Blank without it, like a default profile."
    )
    var instructions: String?

    @Option(help: "Replace only the objects page introduction with text from this file, for controlled evaluations.")
    var objectsPageDescription: String?

    @Flag(help: "Only probe what the object writer writes for an object that follows another's events.")
    var writerProbe = false

    @Flag(help: "Only probe what FM makes of a page, generated as the page's Layout.")
    var pageProbe = false

    func run() async throws {
        if pageProbe {
            try await PageProbe.run(model: try AgentModel(model), runs: runs, temperature: temperature)
            return
        }
        if writerProbe {
            try await WriterProbe.run(model: try AgentModel(model), runs: runs, temperature: temperature)
            return
        }
        let tasks: [EvalTask] =
            task.isEmpty
            ? EvalTask.all
            : EvalTask.all.filter { (request: EvalTask) -> Bool in
                task.contains { (word: String) -> Bool in request.request.localizedCaseInsensitiveContains(word) }
            }
        let service = ModelEvalService(
            model: try AgentModel(model), tasks: tasks, runs: runs, log: URL(fileURLWithPath: log),
            temperature: temperature,
            instructions: try instructions.map { try String(contentsOfFile: $0, encoding: .utf8) } ?? "",
            objectsPageDescription: try objectsPageDescription.map {
                try String(contentsOfFile: $0, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            })
        // Done is done: the group ends when the evals do.
        let configuration = ServiceGroupConfiguration(
            services: [.init(service: service, successTerminationBehavior: .gracefullyShutdownGroup)],
            gracefulShutdownSignals: [.sigterm, .sigint], logger: Logger(label: "eval"))
        try await ServiceGroup(configuration: configuration).run()
    }
}

/// Runs every task `runs` times, each on a node of its own, and reports as it goes. A graceful
/// shutdown stops it between runs' turns, stopping the node it's on.
struct ModelEvalService: Service {
    let model: AgentModel
    let tasks: [EvalTask]
    let runs: Int
    let log: URL
    let temperature: Double
    /// The agent's instructions, as a profile's: blank unless given.
    let instructions: String
    let objectsPageDescription: String?

    func run() async throws {
        try await cancelWhenGracefulShutdown {
            var written = ""
            var passed = 0
            for task in tasks {
                for run in 1...runs {
                    let result = await task.run(
                        with: model, temperature: temperature, instructions: instructions,
                        objectsPageDescription: objectsPageDescription)
                    try Task.checkCancellation()
                    if result.passed { passed += 1 }
                    print(result.line)
                    fflush(stdout)
                    written += "\n##### \(task.request) (run \(run))\n" + result.transcript
                    try written.write(to: log, atomically: true, encoding: .utf8)
                }
            }
            let total = runs * tasks.count
            print("\n\(passed)/\(total) passed")
            written += "\n##### Summary\n\(passed)/\(total) passed\n"
            try written.write(to: log, atomically: true, encoding: .utf8)
        }
    }
}
