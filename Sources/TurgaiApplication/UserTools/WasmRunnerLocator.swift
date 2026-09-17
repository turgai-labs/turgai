#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// Locates the small native host used to execute user-authored Wasm modules.
///
/// An explicit environment override makes development and packaged
/// deployments deterministic. The sibling lookup is the normal SwiftPM/app
/// layout: `Turgai` and `TurgaiWasmRunner` are emitted into the same directory.
public enum WasmRunnerLocator {
    public static func executableURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        currentExecutableURL: URL? = nil
    ) -> URL? {
        if let configured = environment["TURGAI_WASM_RUNNER"],
            let url = executableURL(atPath: configured)
        {
            return url
        }

        let current =
            currentExecutableURL
            ?? CommandLine.arguments.first.map { URL(fileURLWithPath: $0) }
        if let current {
            let sibling =
                current
                .deletingLastPathComponent()
                .appendingPathComponent("TurgaiWasmRunner")
            if let url = executableURL(atPath: sibling.path) {
                return url
            }
        }

        let path = environment["PATH"] ?? ""
        for directory in path.split(separator: ":").map(String.init) {
            let candidate = URL(fileURLWithPath: directory)
                .appendingPathComponent("TurgaiWasmRunner")
            if let url = executableURL(atPath: candidate.path) {
                return url
            }
        }
        return nil
    }

    private static func executableURL(atPath path: String) -> URL? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let url = URL(fileURLWithPath: trimmed).standardizedFileURL
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }
}
