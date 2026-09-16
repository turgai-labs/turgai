import CryptoKit
import HummingbirdBcrypt
import NIOPosix

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// A durable local account used by Norby's future dashboard and API clients.
public struct NorbyAccount: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Equatable, Sendable {
        case pending
        case approved
        case disabled
    }

    public let username: String
    public let status: Status
    public let isAdmin: Bool

    public init(
        username: String,
        status: Status,
        isAdmin: Bool
    ) {
        self.username = username
        self.status = status
        self.isAdmin = isAdmin
    }
}

public struct NorbySession: Codable, Equatable, Sendable {
    public let token: String
    public let username: String
    public let expiresAt: Date
}

public enum NorbyAuthError: Error, Equatable, Sendable {
    case invalidSetupChallenge
    case setupAlreadyCompleted
    case invalidUsername
    case weakPassword
    case usernameTaken
    case unknownUser
    case accountNotApproved
    case accountDisabled
    case invalidCredentials
    case invalidSession
}

/// Local authentication state. Account data and the JWT signing secret live
/// under `.norby/auth`. The first administrator is claimed through a short-lived
/// browser challenge rather than a terminal-visible secret.
public actor NorbyAuth {
    public static let sessionLifetime: TimeInterval = 86_400
    public static let bootstrapChallengeLifetime: TimeInterval = 600

    private struct State: Codable, Sendable {
        var accounts: [String: StoredAccount] = [:]
    }

    private struct StoredAccount: Codable, Sendable {
        let username: String
        let passwordHash: String
        let status: NorbyAccount.Status
        let isAdmin: Bool

        var publicValue: NorbyAccount {
            NorbyAccount(username: username, status: status, isAdmin: isAdmin)
        }
    }

    private struct Claims: Codable, Sendable {
        let sub: String
        let issuer: String
        let issuedAt: Int
        let expiresAt: Int
    }

    private let stateURL: URL
    private let secret: SymmetricKey
    private var state: State
    private var bootstrapChallenges: [String: Date] = [:]
    private var bootstrapInProgress = false

    public init(directory: URL) throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        self.stateURL = directory.appendingPathComponent("accounts.json")

        if let data = try? Data(contentsOf: stateURL) {
            self.state = try JSONDecoder().decode(State.self, from: data)
        } else {
            self.state = State()
        }

        let secretURL = directory.appendingPathComponent("session-secret")
        let secretData: Data
        if let existing = try? Data(contentsOf: secretURL), existing.count >= 32 {
            secretData = existing
        } else {
            secretData = Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
            try secretData.write(to: secretURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: secretURL.path
            )
        }
        self.secret = SymmetricKey(data: secretData)
    }

    public func hasAdmin() -> Bool {
        state.accounts.values.contains { $0.isAdmin && $0.status == .approved }
    }

    public func isAdmin(_ username: String) -> Bool {
        guard let account = state.accounts[username] else { return false }
        return account.isAdmin && account.status == .approved
    }

    public func accounts() -> [NorbyAccount] {
        state.accounts.values.map(\.publicValue).sorted { $0.username < $1.username }
    }

    /// Issues a short-lived, in-memory challenge for the browser that opened
    /// the first-administrator form. The form must submit this value together
    /// with the matching HttpOnly cookie.
    public func issueBootstrapChallenge(now: Date = Date()) -> String {
        bootstrapChallenges = bootstrapChallenges.filter { $0.value > now }
        if bootstrapChallenges.count >= 32,
            let oldest = bootstrapChallenges.min(by: { $0.value < $1.value })?.key
        {
            bootstrapChallenges.removeValue(forKey: oldest)
        }
        let challenge = Self.makeChallenge()
        bootstrapChallenges[challenge] = now.addingTimeInterval(Self.bootstrapChallengeLifetime)
        return challenge
    }

    /// Creates the first administrator. The challenge is consumed before the
    /// password hash awaits, so two concurrent browser submissions cannot both
    /// claim the installation.
    @discardableResult
    public func bootstrap(
        username: String,
        password: String,
        challenge: String,
        confirmation: String,
        now: Date = Date()
    ) async throws -> NorbyAccount {
        guard !hasAdmin() else { throw NorbyAuthError.setupAlreadyCompleted }
        guard !bootstrapInProgress else { throw NorbyAuthError.invalidSetupChallenge }
        guard constantTimeEquals(challenge, confirmation),
            let expiration = bootstrapChallenges.removeValue(forKey: challenge),
            expiration > now
        else {
            throw NorbyAuthError.invalidSetupChallenge
        }
        bootstrapInProgress = true
        defer { bootstrapInProgress = false }
        return try await createAccount(username: username, password: password, isAdmin: true)
    }

    /// Creates a pending member account. An administrator must approve it
    /// before sign-in succeeds.
    @discardableResult
    public func register(username: String, password: String) async throws -> NorbyAccount {
        try await createAccount(username: username, password: password, isAdmin: false)
    }

    public func approve(username: String) throws {
        guard let account = state.accounts[username] else { throw NorbyAuthError.unknownUser }
        state.accounts[username] = StoredAccount(
            username: account.username,
            passwordHash: account.passwordHash,
            status: .approved,
            isAdmin: account.isAdmin
        )
        try persist()
    }

    public func disable(username: String) throws {
        guard let account = state.accounts[username] else { throw NorbyAuthError.unknownUser }
        if account.isAdmin && account.status == .approved {
            let adminCount = state.accounts.values.filter { $0.isAdmin && $0.status == .approved }.count
            guard adminCount > 1 else { throw NorbyAuthError.accountNotApproved }
        }
        state.accounts[username] = StoredAccount(
            username: account.username,
            passwordHash: account.passwordHash,
            status: .disabled,
            isAdmin: account.isAdmin
        )
        try persist()
    }

    public func signIn(username: String, password: String, now: Date = Date()) async throws -> NorbySession {
        guard let account = state.accounts[username] else { throw NorbyAuthError.invalidCredentials }
        guard account.status == .approved else {
            throw account.status == .disabled ? NorbyAuthError.accountDisabled : NorbyAuthError.accountNotApproved
        }
        guard try await verify(password, hash: account.passwordHash) else {
            throw NorbyAuthError.invalidCredentials
        }
        let expiresAt = now.addingTimeInterval(Self.sessionLifetime)
        let claims = Claims(
            sub: username,
            issuer: "norby",
            issuedAt: Int(now.timeIntervalSince1970),
            expiresAt: Int(expiresAt.timeIntervalSince1970)
        )
        let payload = try JSONEncoder().encode(claims)
        let payloadPart = Self.base64URL(payload)
        let headerPart = Self.base64URL(Data("{\"alg\":\"HS256\",\"typ\":\"JWT\"}".utf8))
        let input = "\(headerPart).\(payloadPart)"
        let signature = HMAC<SHA256>.authenticationCode(for: Data(input.utf8), using: secret)
        return NorbySession(
            token: "\(input).\(Self.base64URL(Data(signature)))", username: username, expiresAt: expiresAt)
    }

    public func authenticate(_ token: String, now: Date = Date()) throws -> String {
        let parts = token.split(separator: ".")
        guard parts.count == 3,
            let payload = Self.decodeBase64URL(String(parts[1])),
            let claims = try? JSONDecoder().decode(Claims.self, from: payload),
            claims.issuer == "norby",
            claims.expiresAt > Int(now.timeIntervalSince1970),
            let signatureData = Self.decodeBase64URL(String(parts[2]))
        else { throw NorbyAuthError.invalidSession }

        let input = "\(parts[0]).\(parts[1])"
        let expected = HMAC<SHA256>.authenticationCode(for: Data(input.utf8), using: secret)
        guard constantTimeEquals(Data(expected), signatureData) else { throw NorbyAuthError.invalidSession }
        guard let account = state.accounts[claims.sub], account.status == .approved else {
            throw NorbyAuthError.invalidSession
        }
        return claims.sub
    }

    private func createAccount(username: String, password: String, isAdmin: Bool) async throws -> NorbyAccount {
        guard Self.validUsername(username) else { throw NorbyAuthError.invalidUsername }
        guard password.count >= 12 else { throw NorbyAuthError.weakPassword }
        guard state.accounts[username] == nil else { throw NorbyAuthError.usernameTaken }
        let hash = try await hash(password)
        let account = StoredAccount(
            username: username,
            passwordHash: hash,
            status: isAdmin ? .approved : .pending,
            isAdmin: isAdmin
        )
        state.accounts[username] = account
        try persist()
        return account.publicValue
    }

    private func hash(_ password: String) async throws -> String {
        try await NIOThreadPool.singleton.runIfActive { Bcrypt.hash(password) }
    }

    private func verify(_ password: String, hash: String) async throws -> Bool {
        try await NIOThreadPool.singleton.runIfActive { Bcrypt.verify(password, hash: hash) }
    }

    private func persist() throws {
        try JSONEncoder().encode(state).write(to: stateURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateURL.path)
    }

    private static func makeChallenge() -> String {
        base64URL(Data((0..<24).map { _ in UInt8.random(in: .min ... .max) }))
    }

    private static func validUsername(_ value: String) -> Bool {
        let scalars = value.unicodeScalars
        return (3...64).contains(value.count)
            && scalars.allSatisfy {
                $0.isASCII
                    && (("a"..."z").contains(String($0))
                        || ("A"..."Z").contains(String($0))
                        || ("0"..."9").contains(String($0))
                        || $0 == "_" || $0 == "-" || $0 == ".")
            }
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func decodeBase64URL(_ value: String) -> Data? {
        var base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64)
    }
}

private func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
    constantTimeEquals(Data(lhs.utf8), Data(rhs.utf8))
}

private func constantTimeEquals(_ lhs: Data, _ rhs: Data) -> Bool {
    guard lhs.count == rhs.count else { return false }
    var result: UInt8 = 0
    for (left, right) in zip(lhs, rhs) { result |= left ^ right }
    return result == 0
}
