import WasmKit
import WasmKitWASI

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// Minimal WASI CLI host for Turgai's user tools.
///
/// The host intentionally exposes only the standard WASI streams. No
/// preopened directories, network bridge, native process bridge, or custom
/// host functions are installed. A module receives one JSON request on stdin
/// and writes its result to stdout; diagnostics belong on stderr.
@main
struct TurgaiWasmRunner {
    static func main() {
        do {
            let modulePath = try Self.modulePath()
            let bytes = Array(try Data(contentsOf: URL(fileURLWithPath: modulePath)))
            let module = try parseWasm(bytes: bytes)
            let wasi = try WASIBridgeToHost(
                args: [modulePath],
                environment: [:]
            )
            let exitCode = try wasi.runAndClose { wasi in
                let engine = Engine()
                let store = Store(engine: engine)
                var imports = Imports()
                wasi.link(to: &imports, store: store)
                let instance = try module.instantiate(store: store, imports: imports)
                return try wasi.start(instance)
            }
            Self.exit(Int32(exitCode))
        } catch {
            let message = "TurgaiWasmRunner: \(error)\n"
            FileHandle.standardError.write(Data(message.utf8))
            Self.exit(70)
        }
    }

    private static func exit(_ code: Int32) -> Never {
        #if canImport(Darwin)
            Darwin.exit(code)
        #elseif canImport(Glibc)
            Glibc.exit(code)
        #else
            fatalError("No supported process exit implementation")
        #endif
    }

    private static func modulePath() throws -> String {
        guard CommandLine.arguments.count == 3,
            CommandLine.arguments[1] == "--module"
        else {
            throw RunnerError.usage
        }
        let path = CommandLine.arguments[2]
        guard !path.isEmpty, path.hasSuffix(".wasm") else {
            throw RunnerError.invalidModulePath
        }
        return path
    }
}

private enum RunnerError: Error, CustomStringConvertible {
    case usage
    case invalidModulePath

    var description: String {
        switch self {
        case .usage:
            "usage: TurgaiWasmRunner --module path/to/module.wasm"
        case .invalidModulePath:
            "module path must be a non-empty .wasm path"
        }
    }
}
