import Testing

@testable import TurgaiPersistence

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

@Suite("Turgai's secret key")
struct SecretKeyTests {
    /// A sealed secret opens as it was, but only for the place it was sealed for, and only with
    /// its key.
    @Test func aSecretOpensOnlyWhereItWasSealedAndWithItsKey() throws {
        let key = try SecretKey(bytes: SecretKey.newBytes())
        let tokenB = SecretPlace("channel_tokens", "B")
        let sealed = try key.seal("123:abc", for: tokenB)

        #expect(try key.open(sealed, for: tokenB) == "123:abc")
        #expect(throws: SecretKeyError.unopenable) { try key.open(sealed, for: SecretPlace("channel_tokens", "C")) }
        #expect(throws: SecretKeyError.unopenable) {
            try SecretKey(bytes: SecretKey.newBytes()).open(sealed, for: tokenB)
        }
    }

    /// A key is 32 bytes, or those written as base64.
    @Test func aKeyIsThirtyTwoBytes() throws {
        let bytes = SecretKey.newBytes()
        let key = try SecretKey(base64: bytes.base64EncodedString() + "\n")
        #expect(try key.open(try SecretKey(bytes: bytes).seal("x", for: SecretPlace("t", "1")), for: SecretPlace("t", "1")) == "x")
        #expect(throws: SecretKeyError.notAKey) { try SecretKey(bytes: Data(count: 16)) }
        #expect(throws: SecretKeyError.notAKey) { try SecretKey(base64: "not base64") }
    }
}

@Suite("PostgreSQL's password")
struct PostgresPasswordTests {
    private let configuration = try! TurgaiStorageConfiguration.postgresStore(
        url: URL(string: "postgres://db.example.test:5433/turgai")!, username: "turgai"
    ).postgres!

    /// A password file of the test's own, written with `lines` and `permissions`.
    private func passwordFile(_ lines: String, permissions: Int = 0o600) throws -> URL {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("pgpass-\(UUID().uuidString)")
        try Data(lines.utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: file.path)
        return file
    }

    @Test func pgpasswordIsTakenAsItIs() throws {
        #expect(try configuration.password(environment: ["PGPASSWORD": "s3cret"]) == "s3cret")
    }

    /// The first line that matches, `*` matching any, and `\:` and `\\` read as written.
    @Test func theFirstMatchingLineOfThePasswordFile() throws {
        let file = try passwordFile(
            """
            # a comment
            other.test:5433:turgai:turgai:wrong
            db.example.test:5433:*:turgai:pa\\:ss\\\\word
            *:*:*:*:later
            """)
        defer { try? FileManager.default.removeItem(at: file) }

        #expect(try configuration.password(environment: ["PGPASSFILE": file.path]) == "pa:ss\\word")
    }

    @Test func noMatchingLineIsNoPassword() throws {
        let file = try passwordFile("other.test:5433:turgai:turgai:wrong\n")
        defer { try? FileManager.default.removeItem(at: file) }

        #expect(throws: TurgaiStorageConfigurationError.noPostgresPassword) {
            try configuration.password(environment: ["PGPASSFILE": file.path])
        }
    }

    @Test func aPasswordFileOthersCanReadIsRefused() throws {
        let file = try passwordFile("*:*:*:*:open\n", permissions: 0o644)
        defer { try? FileManager.default.removeItem(at: file) }

        #expect(throws: TurgaiStorageConfigurationError.postgresPasswordFileNotPrivate) {
            try configuration.password(environment: ["PGPASSFILE": file.path])
        }
    }
}
