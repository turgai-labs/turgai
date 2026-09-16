import NorbyPersistence
import Testing

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

@Suite("Norby storage configuration")
struct StorageConfigurationTests {
    @Test("file storage round trips without changing its directory")
    func fileRoundTrip() throws {
        let directory = URL(fileURLWithPath: "/tmp/turgai-data")
        let configuration = try NorbyStorageConfiguration.fileStore(directory: directory)
        let decoded = try JSONDecoder().decode(
            NorbyStorageConfiguration.self,
            from: JSONEncoder().encode(configuration)
        )

        #expect(decoded == .file(directory: directory.standardizedFileURL))
    }

    @Test("PostgreSQL storage keeps connection settings but not a password")
    func postgresRoundTrip() throws {
        let url = URL(string: "postgres://db.example.test:5433/norby")!
        let configuration = try NorbyStorageConfiguration.postgresStore(
            url: url,
            username: " norby "
        )
        let encoded = try JSONEncoder().encode(configuration)
        let decoded = try JSONDecoder().decode(
            NorbyStorageConfiguration.self,
            from: encoded
        )

        #expect(decoded == .postgres(url: url, username: "norby"))
        #expect(String(decoding: encoded, as: UTF8.self).contains("password") == false)
    }

    @Test("invalid PostgreSQL settings are rejected before runtime startup")
    func invalidPostgresSettings() {
        #expect(throws: NorbyStorageConfigurationError.invalidPostgresURL) {
            try NorbyStorageConfiguration.postgresStore(
                url: URL(string: "https://db.example.test/norby")!,
                username: "norby"
            )
        }
        #expect(throws: NorbyStorageConfigurationError.invalidPostgresUsername) {
            try NorbyStorageConfiguration.postgresStore(
                url: URL(string: "postgres://db.example.test/norby")!,
                username: "   "
            )
        }
        #expect(throws: NorbyStorageConfigurationError.invalidPostgresURL) {
            try NorbyStorageConfiguration.postgresStore(
                url: URL(string: "postgres://db.example.test")!,
                username: "norby"
            )
        }
    }

    @Test("file storage rejects non-file URLs")
    func invalidFileURL() {
        #expect(throws: NorbyStorageConfigurationError.invalidFileURL) {
            try NorbyStorageConfiguration.fileStore(
                directory: URL(string: "https://example.com/data")!
            )
        }
    }
}
