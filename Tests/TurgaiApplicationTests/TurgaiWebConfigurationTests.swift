import Foundation
import Testing
import TurgaiWeb

@Suite("Turgai dashboard configuration")
struct TurgaiWebConfigurationTests {
    @Test("missing dashboard state is safe to load")
    func missingState() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let configuration = try TurgaiWebConfiguration.load(directory: directory)

        #expect(configuration.storage == nil)
        #expect(configuration.complete == false)
        #expect(configuration.isReady == false)
    }

    @Test("completed file storage is ready")
    func persistedState() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let state = Data(
            #"{"storage":{"kind":"file","directory":"file:///tmp/turgai-data"},"complete":true}"#
                .utf8
        )
        try state.write(to: directory.appendingPathComponent("setup.json"))

        let configuration = try TurgaiWebConfiguration.load(directory: directory)

        #expect(configuration.complete)
        #expect(configuration.isReady)
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("turgai-web-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
