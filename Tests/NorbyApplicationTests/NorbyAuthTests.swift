import Foundation
import NorbyApplication
import Testing

@Suite("Norby authentication")
struct NorbyAuthTests {
    @Test("first administrator uses the printed token and survives restart")
    func bootstrapAndPersistence() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let auth = try NorbyAuth(directory: directory)
        let token = await auth.setupToken
        let account = try await auth.bootstrap(
            username: "admin",
            password: "correct horse battery staple",
            token: token
        )

        #expect(account.isAdmin)
        #expect(await auth.hasAdmin())
        await #expect(throws: NorbyAuthError.setupAlreadyCompleted) {
            try await auth.bootstrap(username: "second", password: "correct horse battery staple", token: token)
        }

        let restarted = try NorbyAuth(directory: directory)
        let session = try await restarted.signIn(
            username: "admin",
            password: "correct horse battery staple"
        )
        let authenticatedAdmin = try await restarted.authenticate(session.token)
        #expect(authenticatedAdmin == "admin")
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

    @Test("bad credentials and invalid setup tokens are rejected")
    func rejectsInvalidCredentials() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let auth = try NorbyAuth(directory: directory)
        await #expect(throws: NorbyAuthError.invalidSetupToken) {
            try await auth.bootstrap(
                username: "admin",
                password: "correct horse battery staple",
                token: "wrong-token"
            )
        }
        _ = try await auth.bootstrap(
            username: "admin",
            password: "correct horse battery staple",
            token: await auth.setupToken
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
