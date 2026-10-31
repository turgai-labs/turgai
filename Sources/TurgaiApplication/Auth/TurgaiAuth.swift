import Crypto
import HummingbirdBcrypt
import NIOPosix
import TurgaiDomain

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

/// Local authentication state. Accounts are kept in their storage, and the secret that signs
/// sessions in its own. The first administrator is claimed through a short-lived
/// browser challenge rather than a terminal-visible secret.
public actor TurgaiAuth {
    public static let sessionLifetime: TimeInterval = 86_400
    public static let bootstrapChallengeLifetime: TimeInterval = 600

    private struct Claims: Codable, Sendable {
        let sub: String
        let issuer: String
        let issuedAt: Int
        let expiresAt: Int
    }

    private let accounts: AccountStorage
    private let secret: SymmetricKey
    private var bootstrapChallenges: [String: Date] = [:]
    private var bootstrapInProgress = false

    /// Accounts kept in `accounts`, and sessions signed with the secret `sessionSecret` keeps.
    public init(accounts: AccountStorage, sessionSecret: SessionSecretStorage) async throws {
        self.accounts = accounts
        self.secret = SymmetricKey(data: try await sessionSecret.secret())
    }

    public func hasAdmin() async throws -> Bool {
        try await accounts.hasApprovedAdministrator()
    }

    public func accounts() async throws -> [Account] {
        try await accounts.all().map(\.account)
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
    /// claim the installation; and the account is kept only while no approved
    /// administrator exists, in the same write.
    @discardableResult
    public func bootstrap(
        username: String,
        password: String,
        challenge: String,
        confirmation: String,
        now: Date = Date()
    ) async throws -> Account {
        guard try await !hasAdmin() else { throw TurgaiAuthError.setupAlreadyCompleted }
        guard !bootstrapInProgress else { throw TurgaiAuthError.invalidSetupChallenge }
        guard constantTimeEquals(challenge, confirmation),
            let expiration = bootstrapChallenges.removeValue(forKey: challenge),
            expiration > now
        else {
            throw TurgaiAuthError.invalidSetupChallenge
        }
        bootstrapInProgress = true
        defer { bootstrapInProgress = false }
        let account = try await newAccount(username: username, password: password, role: .administrator)
        do {
            guard try await accounts.insertFirstAdministrator(account) else {
                throw TurgaiAuthError.setupAlreadyCompleted
            }
        } catch AccountStorageError.usernameTaken {
            throw TurgaiAuthError.usernameTaken
        }
        return account.account
    }

    /// Creates a chat-only account. It can sign in immediately; an
    /// administrator may promote it to member access later.
    @discardableResult
    public func register(username: String, password: String) async throws -> Account {
        let account = try await newAccount(username: username, password: password, role: .user)
        do {
            try await accounts.insert(account)
        } catch AccountStorageError.usernameTaken {
            throw TurgaiAuthError.usernameTaken
        }
        return account.account
    }

    public func approve(username: String) async throws {
        guard let account = try await accounts.named(username) else { throw TurgaiAuthError.unknownUser }
        try await set(.approved, of: account.id)
    }

    public func approve(id: UUID) async throws {
        try await set(.approved, of: id)
    }

    public func enable(id: UUID) async throws {
        try await set(.approved, of: id)
    }

    public func disable(username: String) async throws {
        guard let account = try await accounts.named(username) else { throw TurgaiAuthError.unknownUser }
        try await set(.disabled, of: account.id)
    }

    public func disable(id: UUID) async throws {
        try await set(.disabled, of: id)
    }

    /// Gives the account `id` `role`: refused when it's unknown, or it would leave no approved
    /// administrator.
    public func setRole(_ id: UUID, role: Account.Role) async throws {
        guard try await accounts.withID(id) != nil else { throw TurgaiAuthError.unknownUser }
        guard try await accounts.setRole(role, id) else { throw TurgaiAuthError.accountNotApproved }
    }

    /// Sets the account `id`'s status: refused when it's unknown, or it would leave no approved
    /// administrator.
    private func set(_ status: Account.Status, of id: UUID) async throws {
        guard try await accounts.withID(id) != nil else { throw TurgaiAuthError.unknownUser }
        guard try await accounts.setStatus(status, id) else { throw TurgaiAuthError.accountNotApproved }
    }

    public func signIn(username: String, password: String, now: Date = Date()) async throws -> TurgaiSession {
        guard let account = try await accounts.named(username) else {
            throw TurgaiAuthError.invalidCredentials
        }
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
        return TurgaiSession(token: try signed(claims), username: username, expiresAt: expiresAt)
    }

    public func authenticate(_ token: String, now: Date = Date()) async throws -> Account {
        guard let payload = verified(token),
            let claims = try? JSONDecoder().decode(Claims.self, from: payload),
            claims.issuer == "turgai",
            claims.expiresAt > Int(now.timeIntervalSince1970)
        else { throw TurgaiAuthError.invalidSession }
        guard let accountID = UUID(uuidString: claims.sub),
            let account = try await accounts.withID(accountID),
            account.status != .disabled
        else {
            throw TurgaiAuthError.invalidSession
        }
        return account.account
    }

    /// A new guest, and the token that says they're them from now on: it never runs out, since it
    /// is who they are.
    public func newGuest() throws -> (guest: UserID, token: String) {
        let guest = UserID.guest(UUID())
        return (guest, try signed(GuestClaims(sub: guest.key, issuer: Self.guestIssuer)))
    }

    /// The guest `token` was signed for: none when it's not a guest's, or Turgai didn't sign it.
    public func guest(from token: String) -> UserID? {
        guard let payload = verified(token),
            let claims = try? JSONDecoder().decode(GuestClaims.self, from: payload),
            claims.issuer == Self.guestIssuer,
            let guest = try? UserID(key: claims.sub),
            guest.isGuest
        else { return nil }
        return guest
    }

    /// What a guest's token says: who they are, and that it's a guest's, never a session's.
    private struct GuestClaims: Codable, Sendable {
        let sub: String
        let issuer: String
    }

    private static let guestIssuer = "turgai-guest"

    /// `claims`, signed with the secret, as a JWT.
    private func signed(_ claims: some Encodable) throws -> String {
        let payloadPart = Self.base64URL(try JSONEncoder().encode(claims))
        let headerPart = Self.base64URL(Data("{\"alg\":\"HS256\",\"typ\":\"JWT\"}".utf8))
        let input = "\(headerPart).\(payloadPart)"
        let signature = HMAC<SHA256>.authenticationCode(for: Data(input.utf8), using: secret)
        return "\(input).\(Self.base64URL(Data(signature)))"
    }

    /// The claims `token` carries, when it's signed with the secret.
    private func verified(_ token: String) -> Data? {
        let parts = token.split(separator: ".")
        guard parts.count == 3,
            let payload = Self.decodeBase64URL(String(parts[1])),
            let signature = Self.decodeBase64URL(String(parts[2]))
        else { return nil }
        let expected = HMAC<SHA256>.authenticationCode(for: Data("\(parts[0]).\(parts[1])".utf8), using: secret)
        return constantTimeEquals(Data(expected), signature) ? payload : nil
    }

    /// A new, approved account for `username`, its password hashed: refused when either isn't
    /// one an account can have, or the username is taken.
    private func newAccount(username: String, password: String, role: Account.Role) async throws -> StoredAccount {
        guard Self.validUsername(username) else { throw TurgaiAuthError.invalidUsername }
        guard password.count >= 12 else { throw TurgaiAuthError.weakPassword }
        // Before the hash, which is slow: the insert decides, but this answers sooner.
        guard try await accounts.named(username) == nil else { throw TurgaiAuthError.usernameTaken }
        return StoredAccount(
            id: UUID(), username: username, passwordHash: try await hash(password), status: .approved, role: role)
    }

    private func hash(_ password: String) async throws -> String {
        try await NIOThreadPool.singleton.runIfActive { Bcrypt.hash(password) }
    }

    private func verify(_ password: String, hash: String) async throws -> Bool {
        try await NIOThreadPool.singleton.runIfActive { Bcrypt.verify(password, hash: hash) }
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
        data.base64EncodedString().replacing("+", with: "-").replacing("/", with: "_")
            .replacing("=", with: "")
    }

    private static func decodeBase64URL(_ value: String) -> Data? {
        var base64 = value.replacing("-", with: "+").replacing("_", with: "/")
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
