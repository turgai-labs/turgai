import ArgumentParser
import Foundation
import Hail
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

    func run() async throws {
        let service = ModelEvalService(model: try AgentModel(model), runs: runs, log: URL(fileURLWithPath: log))
        try await ServiceGroup(services: [service], gracefulShutdownSignals: [.sigterm, .sigint]).run()
    }
}

/// Runs every task `runs` times, each on a node of its own, and reports as it goes. A graceful
/// shutdown stops it between runs' turns, stopping the node it's on.
struct ModelEvalService: Service {
    let model: AgentModel
    let runs: Int
    let log: URL

    func run() async throws {
        try await cancelWhenGracefulShutdown {
            if model.provider == .system {
                let node = try await EvalNode.start(model: model)
                defer { node.stop() }
                try await ToolTokens.report(on: node)
            }
            var written = ""
            var passed = 0
            for task in EvalTask.all {
                for run in 1...runs {
                    let result = await task.run(with: model)
                    try Task.checkCancellation()
                    if result.passed { passed += 1 }
                    print(result.line)
                    fflush(stdout)
                    written += "\n##### \(task.request) (run \(run))\n" + result.transcript
                    try written.write(to: log, atomically: true, encoding: .utf8)
                }
            }
            print("\n\(passed)/\(runs * EvalTask.all.count) passed")
        }
    }
}
