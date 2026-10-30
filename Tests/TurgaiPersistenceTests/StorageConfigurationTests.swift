import Testing
import TurgaiPersistence

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

@Suite("Turgai storage configuration")
struct StorageConfigurationTests {
    @Test("local storage round trips")
    func localRoundTrip() throws {
        let decoded = try JSONDecoder().decode(
            TurgaiStorageConfiguration.self,
            from: JSONEncoder().encode(TurgaiStorageConfiguration.local)
        )

        #expect(decoded == .local)
    }

    @Test("PostgreSQL storage keeps connection settings but not a password")
    func postgresRoundTrip() throws {
        let url = URL(string: "postgres://db.example.test:5433/turgai")!
        let configuration = try TurgaiStorageConfiguration.postgresStore(
            url: url,
            username: " turgai "
        )
        let encoded = try JSONEncoder().encode(configuration)
        let decoded = try JSONDecoder().decode(
            TurgaiStorageConfiguration.self,
            from: encoded
        )

        #expect(decoded == .postgres(url: url, username: "turgai"))
        #expect(String(decoding: encoded, as: UTF8.self).contains("password") == false)
    }

    @Test("invalid PostgreSQL settings are rejected before runtime startup")
    func invalidPostgresSettings() {
        #expect(throws: TurgaiStorageConfigurationError.invalidPostgresURL) {
            try TurgaiStorageConfiguration.postgresStore(
                url: URL(string: "https://db.example.test/turgai")!,
                username: "turgai"
            )
        }
        #expect(throws: TurgaiStorageConfigurationError.invalidPostgresUsername) {
            try TurgaiStorageConfiguration.postgresStore(
                url: URL(string: "postgres://db.example.test/turgai")!,
                username: "   "
            )
        }
        #expect(throws: TurgaiStorageConfigurationError.invalidPostgresURL) {
            try TurgaiStorageConfiguration.postgresStore(
                url: URL(string: "postgres://db.example.test")!,
                username: "turgai"
            )
        }
    }
}
