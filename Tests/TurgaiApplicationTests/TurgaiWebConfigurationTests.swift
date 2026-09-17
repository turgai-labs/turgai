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

        #expect(configuration.telegramToken == nil)
        #expect(configuration.storage == nil)
        #expect(configuration.complete == false)
        #expect(configuration.isReady == false)
    }

    @Test("dashboard state and secret bridge into runtime configuration")
    func persistedState() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let state = Data(
            #"{"storage":{"kind":"file","directory":"file:///tmp/turgai-data"},"telegramChatIDs":[42],"telegramConfigured":true,"complete":true}"#
                .utf8
        )
        try state.write(to: directory.appendingPathComponent("setup.json"))
        try Data("123456:telegram-token".utf8).write(to: directory.appendingPathComponent("telegram-token"))

        let configuration = try TurgaiWebConfiguration.load(directory: directory)

        #expect(configuration.telegramToken == "123456:telegram-token")
        #expect(configuration.telegramChatIDs == [42])
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
