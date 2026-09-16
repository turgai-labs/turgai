import Foundation
import NorbyApplication
import Testing

@Suite("Norby authentication")
struct NorbyAuthTests {
    @Test("first administrator uses a browser challenge and survives restart")
    func bootstrapAndPersistence() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let auth = try NorbyAuth(directory: directory)
        let challenge = await auth.issueBootstrapChallenge()
        let account = try await auth.bootstrap(
            username: "admin",
            password: "correct horse battery staple",
            challenge: challenge,
            confirmation: challenge
        )

        #expect(account.isAdmin)
        #expect(await auth.hasAdmin())
        await #expect(throws: NorbyAuthError.setupAlreadyCompleted) {
            try await auth.bootstrap(
                username: "second",
                password: "correct horse battery staple",
                challenge: challenge,
                confirmation: challenge
            )
        }

        let restarted = try NorbyAuth(directory: directory)
        let session = try await restarted.signIn(
            username: "admin",
            password: "correct horse battery staple"
        )
        let authenticatedAdmin = try await restarted.authenticate(session.token)
        #expect(authenticatedAdmin == "admin")
    }

    @Test("bootstrap challenges expire and are consumed")
    func bootstrapChallengeLifetime() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let auth = try NorbyAuth(directory: directory)
        let issuedAt = Date(timeIntervalSince1970: 1_000)
        let expiredChallenge = await auth.issueBootstrapChallenge(now: issuedAt)
        await #expect(throws: NorbyAuthError.invalidSetupChallenge) {
            try await auth.bootstrap(
                username: "admin",
                password: "correct horse battery staple",
                challenge: expiredChallenge,
                confirmation: expiredChallenge,
                now: issuedAt.addingTimeInterval(NorbyAuth.bootstrapChallengeLifetime + 1)
            )
        }

        let challenge = await auth.issueBootstrapChallenge()
        await #expect(throws: NorbyAuthError.invalidUsername) {
            try await auth.bootstrap(
                username: "x",
                password: "correct horse battery staple",
                challenge: challenge,
                confirmation: challenge
            )
        }
        await #expect(throws: NorbyAuthError.invalidSetupChallenge) {
            try await auth.bootstrap(
                username: "admin",
                password: "correct horse battery staple",
                challenge: challenge,
                confirmation: challenge
            )
        }
    }

    @Test("member registration is pending until approval")
    func pendingRegistration() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let auth = try NorbyAuth(directory: directory)
        let account = try await auth.register(
            username: "member",
            password: "correct horse battery staple"
        )
        #expect(account.status == .pending)
        await #expect(throws: NorbyAuthError.accountNotApproved) {
            try await auth.signIn(username: "member", password: "correct horse battery staple")
        }

        try await auth.approve(username: "member")
        let session = try await auth.signIn(
            username: "member",
            password: "correct horse battery staple"
        )
        let authenticatedMember = try await auth.authenticate(session.token)
        #expect(authenticatedMember == "member")
    }

    @Test("bad credentials and invalid setup challenges are rejected")
    func rejectsInvalidCredentials() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let auth = try NorbyAuth(directory: directory)
        let invalidChallenge = await auth.issueBootstrapChallenge()
        await #expect(throws: NorbyAuthError.invalidSetupChallenge) {
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
        await #expect(throws: NorbyAuthError.invalidCredentials) {
            try await auth.signIn(username: "admin", password: "not the password")
        }
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("norby-auth-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
