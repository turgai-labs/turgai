import CryptoKit
import HummingbirdBcrypt
import NIOPosix

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// A durable local account used by Turgai's future dashboard and API clients.
public struct Account: Codable, Equatable, Sendable {
    public enum Role: String, Codable, Equatable, Sendable {
        case user
        case administrator
        case member
    }

    public enum Status: String, Codable, Equatable, Sendable {
        case pending
        case approved
        case disabled
    }

    public protocol User: Sendable {
        var id: UUID { get }
        var username: String { get }
        var status: Status { get }
    }

    public let id: UUID
    public let username: String
    public let status: Status
    public let role: Role

    public var user: any Account.User {
        switch role {
        case .user: AccountUser(id: id, username: username, status: status)
        case .member: Member(id: id, username: username, status: status)
        case .administrator: Administrator(id: id, username: username, status: status)
        }
    }
    public var administrator: Administrator? {
        role == .administrator
            ? Administrator(id: id, username: username, status: status)
            : nil
    }

    public init(
        id: UUID = UUID(),
        username: String,
        status: Status,
        role: Role
    ) {
        self.id = id
        self.username = username
        self.status = status
        self.role = role
    }
}

public struct Member: Account.User, Codable, Equatable {
    public let id: UUID
    public let username: String
    public let status: Account.Status
}

public struct AccountUser: Account.User, Codable, Equatable {
    public let id: UUID
    public let username: String
    public let status: Account.Status
}

public struct Administrator: Account.User, Codable, Equatable {
    public let id: UUID
    public let username: String
    public let status: Account.Status
}

public struct TurgaiSession: Codable, Equatable, Sendable {
    public let token: String
    public let username: String
    public let expiresAt: Date
}

public enum TurgaiAuthError: Error, Equatable, Sendable {
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
/// under `.turgai/auth`. The first administrator is claimed through a short-lived
/// browser challenge rather than a terminal-visible secret.
public actor TurgaiAuth {
    public static let sessionLifetime: TimeInterval = 86_400
    public static let bootstrapChallengeLifetime: TimeInterval = 600

    private struct State: Codable, Sendable {
        var accounts: [String: StoredAccount] = [:]
    }

    private struct StoredAccount: Codable, Sendable {
        let id: UUID
        let username: String
        let passwordHash: String
        let status: Account.Status
        let role: Account.Role

        init(
            id: UUID = UUID(),
            username: String,
            passwordHash: String,
            status: Account.Status,
            role: Account.Role
        ) {
            self.id = id
            self.username = username
            self.passwordHash = passwordHash
            self.status = status
            self.role = role
        }

        var publicValue: Account {
            Account(
                id: id,
                username: username,
                status: status,
                role: role
            )
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
        state.accounts.values.contains { $0.role == .administrator && $0.status == .approved }
    }

    public func accounts() -> [Account] {
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
    ) async throws -> Account {
        guard !hasAdmin() else { throw TurgaiAuthError.setupAlreadyCompleted }
        guard !bootstrapInProgress else { throw TurgaiAuthError.invalidSetupChallenge }
        guard constantTimeEquals(challenge, confirmation),
            let expiration = bootstrapChallenges.removeValue(forKey: challenge),
            expiration > now
        else {
            throw TurgaiAuthError.invalidSetupChallenge
        }
        bootstrapInProgress = true
        defer { bootstrapInProgress = false }
        return try await createAccount(username: username, password: password, role: .administrator)
    }

    /// Creates a chat-only account. It can sign in immediately; an
    /// administrator may promote it to member access later.
    @discardableResult
    public func register(username: String, password: String) async throws -> Account {
        try await createAccount(username: username, password: password, role: .user)
    }

    public func approve(username: String) throws {
        guard let account = state.accounts[username] else { throw TurgaiAuthError.unknownUser }
        state.accounts[username] = StoredAccount(
            id: account.id,
            username: account.username,
            passwordHash: account.passwordHash,
            status: .approved,
            role: account.role
        )
        try persist()
    }

    public func approve(id: UUID) throws {
        let (key, account) = try accountEntry(id: id)
        state.accounts[key] = StoredAccount(
            id: account.id,
            username: account.username,
            passwordHash: account.passwordHash,
            status: .approved,
            role: account.role
        )
        try persist()
    }

    public func enable(id: UUID) throws {
        let (key, account) = try accountEntry(id: id)
        state.accounts[key] = StoredAccount(
            id: account.id,
            username: account.username,
            passwordHash: account.passwordHash,
            status: .approved,
            role: account.role
        )
        try persist()
    }

    public func disable(username: String) throws {
        guard let account = state.accounts[username] else { throw TurgaiAuthError.unknownUser }
        if account.role == .administrator && account.status == .approved {
            let adminCount = state.accounts.values.filter { $0.role == .administrator && $0.status == .approved }.count
            guard adminCount > 1 else { throw TurgaiAuthError.accountNotApproved }
        }
        state.accounts[username] = StoredAccount(
            id: account.id,
            username: account.username,
            passwordHash: account.passwordHash,
            status: .disabled,
            role: account.role
        )
        try persist()
    }

    public func disable(id: UUID) throws {
        let (key, account) = try accountEntry(id: id)
        if account.role == .administrator && account.status == .approved {
            let adminCount = state.accounts.values.filter { $0.role == .administrator && $0.status == .approved }.count
            guard adminCount > 1 else { throw TurgaiAuthError.accountNotApproved }
        }
        state.accounts[key] = StoredAccount(
            id: account.id,
            username: account.username,
            passwordHash: account.passwordHash,
            status: .disabled,
            role: account.role
        )
        try persist()
    }

    public func setRole(_ id: UUID, role: Account.Role) throws {
        let (key, account) = try accountEntry(id: id)
        if role != .administrator && account.role == .administrator && account.status == .approved {
            let adminCount = state.accounts.values.filter { $0.role == .administrator && $0.status == .approved }.count
            guard adminCount > 1 else { throw TurgaiAuthError.accountNotApproved }
        }
        state.accounts[key] = StoredAccount(
            id: account.id,
            username: account.username,
            passwordHash: account.passwordHash,
            status: account.status,
            role: role
        )
        try persist()
    }

    private func accountEntry(id: UUID) throws -> (String, StoredAccount) {
        guard let entry = state.accounts.first(where: { $0.value.id == id }) else {
            throw TurgaiAuthError.unknownUser
        }
        return entry
    }

    public func signIn(username: String, password: String, now: Date = Date()) async throws -> TurgaiSession {
        guard let account = state.accounts[username] else { throw TurgaiAuthError.invalidCredentials }
        guard account.status != .disabled else { throw TurgaiAuthError.accountDisabled }
        guard try await verify(password, hash: account.passwordHash) else {
            throw TurgaiAuthError.invalidCredentials
        }
        let expiresAt = now.addingTimeInterval(Self.sessionLifetime)
        let claims = Claims(
            sub: account.id.uuidString,
            issuer: "turgai",
            issuedAt: Int(now.timeIntervalSince1970),
            expiresAt: Int(expiresAt.timeIntervalSince1970)
        )
        let payload = try JSONEncoder().encode(claims)
        let payloadPart = Self.base64URL(payload)
        let headerPart = Self.base64URL(Data("{\"alg\":\"HS256\",\"typ\":\"JWT\"}".utf8))
        let input = "\(headerPart).\(payloadPart)"
        let signature = HMAC<SHA256>.authenticationCode(for: Data(input.utf8), using: secret)
        return TurgaiSession(
            token: "\(input).\(Self.base64URL(Data(signature)))", username: username, expiresAt: expiresAt)
    }

    public func authenticate(_ token: String, now: Date = Date()) throws -> Account {
        let parts = token.split(separator: ".")
        guard parts.count == 3,
            let payload = Self.decodeBase64URL(String(parts[1])),
            let claims = try? JSONDecoder().decode(Claims.self, from: payload),
            claims.issuer == "turgai",
            claims.expiresAt > Int(now.timeIntervalSince1970),
            let signatureData = Self.decodeBase64URL(String(parts[2]))
        else { throw TurgaiAuthError.invalidSession }

        let input = "\(parts[0]).\(parts[1])"
        let expected = HMAC<SHA256>.authenticationCode(for: Data(input.utf8), using: secret)
        guard constantTimeEquals(Data(expected), signatureData) else { throw TurgaiAuthError.invalidSession }
        guard let accountID = UUID(uuidString: claims.sub),
            let account = state.accounts.values.first(where: { $0.id == accountID }),
            account.status != .disabled
        else {
            throw TurgaiAuthError.invalidSession
        }
        return account.publicValue
    }

    private func createAccount(username: String, password: String, role: Account.Role) async throws -> Account {
        guard Self.validUsername(username) else { throw TurgaiAuthError.invalidUsername }
        guard password.count >= 12 else { throw TurgaiAuthError.weakPassword }
        guard state.accounts[username] == nil else { throw TurgaiAuthError.usernameTaken }
        let hash = try await hash(password)
        let account = StoredAccount(
            id: UUID(),
            username: username,
            passwordHash: hash,
            status: .approved,
            role: role
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
