import Hail

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// Shared native-process policy for user-authored workflow stages and legacy
/// one-shot process tools. User workflows do not need to know that this is an
/// OS process policy; they only choose an Execute stage.
enum UserProcessSupport {
    static let maximumOutputBytes = 16 * 1024 * 1024

    static func resolveExecutable(
        _ value: String,
        relativeTo workspaceRoot: String,
        pathEnvironment: String
    ) -> String {
        if value.contains("/") {
            if value.hasPrefix("/") { return value }
            return URL(fileURLWithPath: workspaceRoot)
                .appendingPathComponent(value)
                .standardizedFileURL
                .path
        }
        for directory in pathEnvironment.split(separator: ":").map(String.init) {
            let candidate = URL(fileURLWithPath: directory)
                .appendingPathComponent(value)
                .path
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return value
    }

    static func sandboxPolicy(
        toolDirectory: String,
        workspaceRoot: String,
        executable: String,
        writeDirectory: String? = nil,
        allowWorkspaceWrite: Bool = true
    ) -> ProcessSandboxPolicy {
        var readOnlyPaths = [toolDirectory]

        #if os(macOS)
            readOnlyPaths += [
                "/System",
                "/usr",
                "/bin",
                "/sbin",
                "/private/var/db/dyld",
            ]
            for path in ["/usr/local", "/opt/homebrew"]
            where
                FileManager.default.fileExists(atPath: path)
            {
                readOnlyPaths.append(path)
            }
        #elseif os(Linux)
            readOnlyPaths += [
                "/usr",
                "/bin",
                "/sbin",
                "/lib",
                "/lib64",
                "/etc",
            ]
        #endif

        let writableRoot =
            writeDirectory.map {
                URL(fileURLWithPath: workspaceRoot)
                    .appendingPathComponent($0)
                    .standardizedFileURL.path
            } ?? workspaceRoot

        return ProcessSandboxPolicy(
            readOnlyPaths: readOnlyPaths,
            readWritePaths: allowWorkspaceWrite ? [writableRoot] : [],
            network: .denied,
            environment: .clear
        )
    }

    static func workspaceDirectory(
        _ path: String?,
        workspaceRoot: String
    ) throws -> String {
        guard let path else { return workspaceRoot }
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("/") else {
            throw UserWorkflowError.invalidScriptPath(path)
        }
        let root = URL(fileURLWithPath: workspaceRoot)
            .standardizedFileURL.resolvingSymlinksInPath()
        let candidate = root.appendingPathComponent(trimmed)
            .standardizedFileURL.resolvingSymlinksInPath()
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard candidate.path == root.path || candidate.path.hasPrefix(rootPath) else {
            throw UserWorkflowError.invalidScriptPath(path)
        }
        return candidate.path
    }

    static func scriptURL(
        _ path: String,
        toolDirectory: URL
    ) throws -> URL {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("/") else {
            throw UserWorkflowError.invalidScriptPath(path)
        }

        let root = toolDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let candidate =
            toolDirectory
            .appendingPathComponent(trimmed)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard candidate.path.hasPrefix(rootPath) else {
            throw UserWorkflowError.invalidScriptPath(path)
        }
        guard FileManager.default.isReadableFile(atPath: candidate.path) else {
            throw UserWorkflowError.scriptUnavailable(path)
        }
        return candidate
    }
}
