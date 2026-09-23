import Foundation
import Testing
import TurgaiApplication

@Suite("Turgai authentication")
struct TurgaiAuthTests {
    @Test("first administrator uses a browser challenge and survives restart")
    func bootstrapAndPersistence() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let auth = try TurgaiAuth(directory: directory)
        let challenge = await auth.issueBootstrapChallenge()
        let account = try await auth.bootstrap(
            username: "admin",
            password: "correct horse battery staple",
            challenge: challenge,
            confirmation: challenge
        )

        #expect(account.administrator != nil)
        #expect(await auth.hasAdmin())
        await #expect(throws: TurgaiAuthError.setupAlreadyCompleted) {
            try await auth.bootstrap(
                username: "second",
                password: "correct horse battery staple",
                challenge: challenge,
                confirmation: challenge
            )
        }

        let restarted = try TurgaiAuth(directory: directory)
        let session = try await restarted.signIn(
            username: "admin",
            password: "correct horse battery staple"
        )
        let authenticatedAdmin = try await restarted.authenticate(session.token)
        #expect(authenticatedAdmin.username == "admin")
    }

    @Test("bootstrap challenges expire and are consumed")
    func bootstrapChallengeLifetime() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let auth = try TurgaiAuth(directory: directory)
        let issuedAt = Date(timeIntervalSince1970: 1_000)
        let expiredChallenge = await auth.issueBootstrapChallenge(now: issuedAt)
        await #expect(throws: TurgaiAuthError.invalidSetupChallenge) {
            try await auth.bootstrap(
                username: "admin",
                password: "correct horse battery staple",
                challenge: expiredChallenge,
                confirmation: expiredChallenge,
                now: issuedAt.addingTimeInterval(TurgaiAuth.bootstrapChallengeLifetime + 1)
            )
        }

        let challenge = await auth.issueBootstrapChallenge()
        await #expect(throws: TurgaiAuthError.invalidUsername) {
            try await auth.bootstrap(
                username: "x",
                password: "correct horse battery staple",
                challenge: challenge,
                confirmation: challenge
            )
        }
        await #expect(throws: TurgaiAuthError.invalidSetupChallenge) {
            try await auth.bootstrap(
                username: "admin",
                password: "correct horse battery staple",
                challenge: challenge,
                confirmation: challenge
            )
        }
    }

    @Test("member registration is approved and can sign in immediately")
    func immediateRegistration() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let auth = try TurgaiAuth(directory: directory)
        let account = try await auth.register(
            username: "member",
            password: "correct horse battery staple"
        )
        #expect(account.status == .approved)

        let session = try await auth.signIn(
            username: "member",
            password: "correct horse battery staple"
        )
        let authenticatedMember = try await auth.authenticate(session.token)
        #expect(authenticatedMember.username == "member")
    }

    @Test("bad credentials and invalid setup challenges are rejected")
    func rejectsInvalidCredentials() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let auth = try TurgaiAuth(directory: directory)
        let invalidChallenge = await auth.issueBootstrapChallenge()
        await #expect(throws: TurgaiAuthError.invalidSetupChallenge) {
            try await auth.bootstrap(
                username: "admin",
                password: "correct horse battery staple",
                challenge: invalidChallenge,
                confirmation: "wrong-challenge"
            )
        }
        let challenge = await auth.issueBootstrapChallenge()
        _ = try await auth.bootstrap(
            username: "admin",
            password: "correct horse battery staple",
            challenge: challenge,
            confirmation: challenge
        )
        await #expect(throws: TurgaiAuthError.invalidCredentials) {
            try await auth.signIn(username: "admin", password: "not the password")
        }
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("turgai-auth-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
